Set-StrictMode -Version Latest

if ($null -eq ('PrivateMarker.ProcessBoundary' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace PrivateMarker
{
    public sealed class BoundedReadResult
    {
        public byte[] Data { get; set; }
        public bool LimitExceeded { get; set; }
    }

    public static class BoundedStreamReader
    {
        public static async Task<BoundedReadResult> ReadAsync(Stream stream, int maximumBytes)
        {
            using (var output = new MemoryStream())
            {
                var buffer = new byte[8192];
                while (true)
                {
                    var read = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if (read == 0)
                    {
                        return new BoundedReadResult {
                            Data = output.ToArray(),
                            LimitExceeded = false
                        };
                    }

                    if (output.Length + read > maximumBytes)
                    {
                        return new BoundedReadResult {
                            Data = output.ToArray(),
                            LimitExceeded = true
                        };
                    }
                    output.Write(buffer, 0, read);
                }
            }
        }
    }

    public static class ProcessBoundary
    {
        private const uint JobObjectExtendedLimitInformation = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            uint informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr CreateKillOnCloseJob()
        {
            var job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            var limits = new ExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            var length = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            var pointer = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(limits, pointer, false);
                if (!SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    pointer,
                    (uint)length))
                {
                    var error = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    throw new Win32Exception(error);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }
            return job;
        }

        public static void Assign(IntPtr job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public static void Close(IntPtr job)
        {
            if (job != IntPtr.Zero && !CloseHandle(job))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }

    public sealed class ContainedProcess : IDisposable
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint ResumeFailed = 0xFFFFFFFF;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitFailed = 0xFFFFFFFF;
        private static readonly IntPtr ProcThreadAttributeHandleList =
            new IntPtr(0x00020002);

        private IntPtr jobHandle;
        private IntPtr processHandle;
        private bool disposed;
        private int remainingSyntheticJobCloseFailures;
        private readonly bool syntheticJobCloseProbe;

        public Stream StandardInput { get; private set; }
        public Stream StandardOutput { get; private set; }
        public Stream StandardError { get; private set; }
        public static int LastSyntheticFailureProcessId { get; private set; }
        public static int LastSyntheticJobCloseAttempts { get; private set; }
        public static int LastSyntheticDirectTerminateAttempts { get; private set; }
        public static bool LastSyntheticJobCloseRetrySucceeded { get; private set; }

        private ContainedProcess(
            IntPtr childProcess,
            Stream standardInput,
            Stream standardOutput,
            Stream standardError,
            IntPtr job,
            int syntheticJobCloseFailures)
        {
            processHandle = childProcess;
            StandardInput = standardInput;
            StandardOutput = standardOutput;
            StandardError = standardError;
            jobHandle = job;
            remainingSyntheticJobCloseFailures =
                syntheticJobCloseFailures;
            syntheticJobCloseProbe =
                syntheticJobCloseFailures > 0;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public uint Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public int ProcessId;
            public int ThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out IntPtr readPipe,
            out IntPtr writePipe,
            ref SecurityAttributes pipeAttributes,
            int size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(
            IntPtr handle,
            uint mask,
            uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(
            IntPtr attributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            IntPtr handle,
            uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(
            IntPtr process,
            out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        private static string Quote(string value)
        {
            if (String.IsNullOrEmpty(value))
            {
                return "\"\"";
            }
            if (value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
            {
                return value;
            }

            var result = new StringBuilder("\"");
            var backslashes = 0;
            foreach (var character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', (backslashes * 2) + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static StringBuilder BuildCommandLine(
            string filePath,
            string[] arguments)
        {
            var commandLine = new StringBuilder(Quote(filePath));
            foreach (var argument in arguments)
            {
                commandLine.Append(' ');
                commandLine.Append(Quote(argument ?? String.Empty));
            }
            return commandLine;
        }

        private static IntPtr BuildEnvironmentBlock(IDictionary environment)
        {
            var entries = new List<string>();
            foreach (DictionaryEntry entry in environment)
            {
                var name = Convert.ToString(entry.Key);
                var value = Convert.ToString(entry.Value) ?? String.Empty;
                if (String.IsNullOrEmpty(name) ||
                    name.IndexOf('=') >= 0 ||
                    name.IndexOf('\0') >= 0 ||
                    value.IndexOf('\0') >= 0)
                {
                    throw new ArgumentException("Invalid child environment entry.");
                }
                entries.Add(name + "=" + value);
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            var block = String.Join("\0", entries.ToArray()) + "\0\0";
            return Marshal.StringToHGlobalUni(block);
        }

        private static void CloseOwnedHandle(ref IntPtr handle)
        {
            if (handle != IntPtr.Zero)
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
            }
        }

        public static ContainedProcess Start(
            string filePath,
            string[] arguments,
            IDictionary environment,
            string workingDirectory,
            string testFailureMode,
            string jobCloseFailureMode,
            int launchTimeoutMilliseconds)
        {
            var launchClock = Stopwatch.StartNew();
            // fault injection時だけ直前PIDを公開し、production pathには
            // process-globalな観測stateを持ち込まない。
            if (!String.IsNullOrEmpty(testFailureMode))
            {
                LastSyntheticFailureProcessId = 0;
            }
            if (!String.IsNullOrEmpty(jobCloseFailureMode))
            {
                LastSyntheticJobCloseAttempts = 0;
                LastSyntheticDirectTerminateAttempts = 0;
                LastSyntheticJobCloseRetrySucceeded = false;
            }

            IntPtr stdinRead = IntPtr.Zero;
            IntPtr stdinWrite = IntPtr.Zero;
            IntPtr stdoutRead = IntPtr.Zero;
            IntPtr stdoutWrite = IntPtr.Zero;
            IntPtr stderrRead = IntPtr.Zero;
            IntPtr stderrWrite = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr inheritedHandleList = IntPtr.Zero;
            IntPtr job = IntPtr.Zero;
            var processInformation = new ProcessInformation();
            FileStream stdin = null;
            FileStream stdout = null;
            FileStream stderr = null;
            var processCreated = false;
            var processAssigned = false;
            var attributeListInitialized = false;
            try
            {
                var attributes = new SecurityAttributes {
                    Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                    InheritHandle = true
                };
                if (!CreatePipe(out stdinRead, out stdinWrite, ref attributes, 0) ||
                    !CreatePipe(out stdoutRead, out stdoutWrite, ref attributes, 0) ||
                    !CreatePipe(out stderrRead, out stderrWrite, ref attributes, 0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreatePipe failed.");
                }
                if (!SetHandleInformation(stdinWrite, HandleFlagInherit, 0) ||
                    !SetHandleInformation(stdoutRead, HandleFlagInherit, 0) ||
                    !SetHandleInformation(stderrRead, HandleFlagInherit, 0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetHandleInformation failed.");
                }

                var attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    1,
                    0,
                    ref attributeListSize);
                if (attributeListSize == IntPtr.Zero)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList size query failed.");
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(
                    attributeList,
                    1,
                    0,
                    ref attributeListSize))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList failed.");
                }
                attributeListInitialized = true;

                inheritedHandleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(inheritedHandleList, 0, stdinRead);
                Marshal.WriteIntPtr(inheritedHandleList, IntPtr.Size, stdoutWrite);
                Marshal.WriteIntPtr(
                    inheritedHandleList,
                    IntPtr.Size * 2,
                    stderrWrite);
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    ProcThreadAttributeHandleList,
                    inheritedHandleList,
                    new IntPtr(IntPtr.Size * 3),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "UpdateProcThreadAttribute failed.");
                }

                var startupInfo = new StartupInfoEx();
                startupInfo.StartupInfo.Size =
                    Marshal.SizeOf(typeof(StartupInfoEx));
                startupInfo.StartupInfo.Flags = StartfUseStdHandles;
                startupInfo.StartupInfo.StandardInput = stdinRead;
                startupInfo.StartupInfo.StandardOutput = stdoutWrite;
                startupInfo.StartupInfo.StandardError = stderrWrite;
                startupInfo.AttributeList = attributeList;

                job = ProcessBoundary.CreateKillOnCloseJob();
                environmentBlock = BuildEnvironmentBlock(environment);
                if (!CreateProcessW(
                    filePath,
                    BuildCommandLine(filePath, arguments),
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateSuspended |
                        CreateUnicodeEnvironment |
                        CreateNoWindow |
                        ExtendedStartupInfoPresent,
                    environmentBlock,
                    String.IsNullOrWhiteSpace(workingDirectory)
                        ? null
                        : workingDirectory,
                    ref startupInfo,
                    out processInformation))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateProcessW failed.");
                }
                processCreated = true;
                if (!String.IsNullOrEmpty(testFailureMode))
                {
                    LastSyntheticFailureProcessId =
                        processInformation.ProcessId;
                }

                // Job割当前のfailureでもtargetはsuspendedのまま。catchが
                // terminate+waitを確認してからだけ元failureを返す。
                if (String.Equals(
                    testFailureMode,
                    "assign",
                    StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Synthetic Job assignment failure.");
                }
                ProcessBoundary.Assign(job, processInformation.Process);
                processAssigned = true;

                var stdinHandle = new SafeFileHandle(stdinWrite, true);
                stdinWrite = IntPtr.Zero;
                var stdoutHandle = new SafeFileHandle(stdoutRead, true);
                stdoutRead = IntPtr.Zero;
                var stderrHandle = new SafeFileHandle(stderrRead, true);
                stderrRead = IntPtr.Zero;
                stdin = new FileStream(
                    stdinHandle,
                    FileAccess.Write,
                    8192,
                    false);
                stdout = new FileStream(
                    stdoutHandle,
                    FileAccess.Read,
                    8192,
                    false);
                stderr = new FileStream(
                    stderrHandle,
                    FileAccess.Read,
                    8192,
                    false);

                CloseOwnedHandle(ref stdinRead);
                CloseOwnedHandle(ref stdoutWrite);
                CloseOwnedHandle(ref stderrWrite);

                // Job割当後・resume前のfailureで、kill-on-closeとbounded waitを
                // target codeを一度も実行せず実測する。
                if (String.Equals(
                    testFailureMode,
                    "resume",
                    StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Synthetic ResumeThread failure.");
                }
                // PowerShell側で残りdeadlineを渡し、suspended targetを
                // deadline後にresumeする競合をnative境界で閉じる。
                if (launchTimeoutMilliseconds <= 0 ||
                    launchClock.ElapsedMilliseconds >=
                        launchTimeoutMilliseconds)
                {
                    throw new TimeoutException(
                        "Contained launch deadline expired before resume.");
                }
                if (ResumeThread(processInformation.Thread) == ResumeFailed)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "ResumeThread failed.");
                }
                CloseOwnedHandle(ref processInformation.Thread);

                var result = new ContainedProcess(
                    processInformation.Process,
                    stdin,
                    stdout,
                    stderr,
                    job,
                    String.Equals(
                        jobCloseFailureMode,
                        "once",
                        StringComparison.Ordinal)
                            ? 1
                            : 0);
                // native process/stream/Jobの所有権はresultへ一括移譲する。
                // callerのfinallyがContainedProcess.Disposeを必ず呼ぶため、
                // success pathでも3本のFileStreamを明示的に回収できる。
                processInformation.Process = IntPtr.Zero;
                stdin = null;
                stdout = null;
                stderr = null;
                job = IntPtr.Zero;
                return result;
            }
            catch (Exception launchFailure)
            {
                Exception cleanupFailure = null;
                if (processCreated)
                {
                    if (processAssigned && job != IntPtr.Zero)
                    {
                        // Job close失敗時はfinally再試行用にhandleを残し、
                        // direct terminateもfallbackとして必ず試す。
                        var assignedJob = job;
                        if (CloseHandle(assignedJob))
                        {
                            job = IntPtr.Zero;
                        }
                        else
                        {
                            cleanupFailure = new Win32Exception(
                                Marshal.GetLastWin32Error(),
                                "Closing the assigned Job failed.");
                            if (!TerminateProcess(
                                processInformation.Process,
                                1))
                            {
                                var terminateFailure =
                                    new Win32Exception(
                                        Marshal.GetLastWin32Error(),
                                        "Fallback process termination failed.");
                                cleanupFailure = new AggregateException(
                                    cleanupFailure,
                                    terminateFailure);
                            }
                        }
                    }
                    else if (!TerminateProcess(
                        processInformation.Process,
                        1))
                    {
                        cleanupFailure = new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "Terminating the suspended process failed.");
                    }

                    var waitResult = WaitForSingleObject(
                        processInformation.Process,
                        5000);
                    if (waitResult != WaitObject0)
                    {
                        Exception waitFailure =
                            waitResult == WaitFailed
                                ? (Exception)new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Waiting for launch-failure cleanup failed.")
                                : new TimeoutException(
                                    "Launch-failure cleanup exceeded 5000 ms.");
                        cleanupFailure = cleanupFailure == null
                            ? waitFailure
                            : new AggregateException(
                                cleanupFailure,
                                waitFailure);
                    }
                }
                if (cleanupFailure != null)
                {
                    throw new AggregateException(
                        "Contained child launch cleanup failed.",
                        launchFailure,
                        cleanupFailure);
                }
                throw;
            }
            finally
            {
                if (environmentBlock != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(environmentBlock);
                }
                if (attributeListInitialized)
                {
                    DeleteProcThreadAttributeList(attributeList);
                }
                if (attributeList != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(attributeList);
                }
                if (inheritedHandleList != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(inheritedHandleList);
                }
                CloseOwnedHandle(ref stdinRead);
                CloseOwnedHandle(ref stdinWrite);
                CloseOwnedHandle(ref stdoutRead);
                CloseOwnedHandle(ref stdoutWrite);
                CloseOwnedHandle(ref stderrRead);
                CloseOwnedHandle(ref stderrWrite);
                CloseOwnedHandle(ref processInformation.Thread);
                CloseOwnedHandle(ref processInformation.Process);
                if (job != IntPtr.Zero)
                {
                    CloseOwnedHandle(ref job);
                }
                if (stdin != null)
                {
                    stdin.Dispose();
                }
                if (stdout != null)
                {
                    stdout.Dispose();
                }
                if (stderr != null)
                {
                    stderr.Dispose();
                }
            }
        }

        public bool WaitForExit(int milliseconds)
        {
            return WaitForSingleObject(
                processHandle,
                (uint)milliseconds) == WaitObject0;
        }

        public bool HasExited
        {
            get {
                return WaitForSingleObject(processHandle, 0) == WaitObject0;
            }
        }

        public int ExitCode
        {
            get
            {
                uint exitCode;
                if (!GetExitCodeProcess(processHandle, out exitCode))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return unchecked((int)exitCode);
            }
        }

        public void CloseJob()
        {
            if (jobHandle == IntPtr.Zero)
            {
                return;
            }
            if (syntheticJobCloseProbe)
            {
                LastSyntheticJobCloseAttempts++;
            }
            if (remainingSyntheticJobCloseFailures > 0)
            {
                remainingSyntheticJobCloseFailures--;
                throw new InvalidOperationException(
                    "Synthetic Job close failure.");
            }
            var handle = jobHandle;
            ProcessBoundary.Close(handle);
            // ownershipはClose成功後だけ放棄する。failure時はretry用に保持する。
            jobHandle = IntPtr.Zero;
            if (syntheticJobCloseProbe &&
                LastSyntheticJobCloseAttempts > 1)
            {
                LastSyntheticJobCloseRetrySucceeded = true;
            }
        }

        public void Terminate()
        {
            if (processHandle == IntPtr.Zero ||
                WaitForSingleObject(processHandle, 0) == WaitObject0)
            {
                return;
            }
            if (syntheticJobCloseProbe)
            {
                LastSyntheticDirectTerminateAttempts++;
            }
            if (!TerminateProcess(processHandle, 1) &&
                WaitForSingleObject(processHandle, 0) != WaitObject0)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Fallback process termination failed.");
            }
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            try
            {
                CloseJob();
            }
            finally
            {
                try
                {
                    StandardInput.Dispose();
                    StandardOutput.Dispose();
                    StandardError.Dispose();
                }
                finally
                {
                    CloseOwnedHandle(ref processHandle);
                }
            }
            // CloseJob失敗時はここへ到達せず、保持したJob handleを次回Disposeで
            // retryできる。stream/process handleのDisposeは冪等に再実行できる。
            disposed = true;
        }
    }

    public static class PosixSignal
    {
        private const int SigKill = 9;
        private const int ErrorNoSuchProcess = 3;

        [DllImport("libc", SetLastError = true)]
        private static extern int kill(int pid, int signal);

        [DllImport("libc", SetLastError = true)]
        private static extern int getpgid(int pid);

        public static bool IsSuccessfulResult(int result, int error)
        {
            return result == 0 ||
                (result == -1 && error == ErrorNoSuchProcess);
        }

        public static bool IsProcessGroupLeader(int processId)
        {
            return processId > 0 && getpgid(processId) == processId;
        }

        public static bool KillProcessGroup(int processGroupId)
        {
            if (processGroupId <= 0)
            {
                return false;
            }

            var result = kill(-processGroupId, SigKill);
            var error = result == 0 ? 0 : Marshal.GetLastWin32Error();
            return IsSuccessfulResult(result, error);
        }
    }
}
'@
}

function Test-PrivateMarkerWindowsHost {
    try {
        return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows
        )
    }
    catch {
        # RuntimeInformation が無い旧hostでも、ambient変数ではなくruntime特性を使う。
        return [System.IO.Path]::DirectorySeparatorChar -eq [char]92
    }
}

function ConvertTo-PrivateMarkerProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ([string]::IsNullOrEmpty($Argument)) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # PowerShell 5.1 には ArgumentList がないため、native 引数規則で引用する。
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (($backslashes * 2) + 1))
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Get-PrivateMarkerPosixSetsidArguments {
    param(
        [string]$PowerShellExecutable,
        [string]$EncodedCommand
    )

    # BusyBox / util-linuxの共通契約は先頭operandのprogram pathだけに絞る。
    # util-linux固有optionを追加するとBusyBox hostが常時fail closedになる。
    return [string[]]@(
        $PowerShellExecutable,
        '-NoProfile',
        '-EncodedCommand',
        $EncodedCommand
    )
}

function Set-PrivateMarkerHermeticGitEnvironment {
    param(
        [System.Collections.IDictionary]$Environment,
        [string]$IsolationRoot
    )

    # 親環境は触らず、Git 子 process の clone だけから全 GIT_* を除去する。
    foreach ($name in @($Environment.Keys | ForEach-Object { "$_" })) {
        if ($name -match '^GIT_') {
            $Environment.Remove($name)
        }
    }
    foreach ($name in @('HOME', 'USERPROFILE', 'XDG_CONFIG_HOME')) {
        $Environment.Remove($name)
    }

    $homeDirectory = Join-Path $IsolationRoot 'home'
    $xdgDirectory = Join-Path $IsolationRoot 'xdg'
    $hooksDirectory = Join-Path $IsolationRoot 'empty-hooks'
    $templateDirectory = Join-Path $IsolationRoot 'empty-template'
    foreach ($directory in @($homeDirectory, $xdgDirectory, $hooksDirectory, $templateDirectory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $emptyGlobalConfig = Join-Path $IsolationRoot 'empty-global.gitconfig'
    $emptySystemConfig = Join-Path $IsolationRoot 'empty-system.gitconfig'
    $emptyAttributes = Join-Path $IsolationRoot 'empty-attributes'
    $emptyExcludes = Join-Path $IsolationRoot 'empty-excludes'
    foreach ($emptyFile in @($emptyGlobalConfig, $emptySystemConfig, $emptyAttributes, $emptyExcludes)) {
        if (-not (Test-Path -LiteralPath $emptyFile -PathType Leaf)) {
            [System.IO.File]::WriteAllText($emptyFile, '', [System.Text.UTF8Encoding]::new($false))
        }
    }

    $Environment['HOME'] = $homeDirectory
    $Environment['USERPROFILE'] = $homeDirectory
    $Environment['XDG_CONFIG_HOME'] = $xdgDirectory
    $Environment['LC_ALL'] = 'C'
    $Environment['LANG'] = 'C'
    $Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $Environment['GIT_ATTR_NOSYSTEM'] = '1'
    $Environment['GIT_CONFIG_GLOBAL'] = $emptyGlobalConfig
    $Environment['GIT_CONFIG_SYSTEM'] = $emptySystemConfig
    $Environment['GIT_TERMINAL_PROMPT'] = '0'
    $Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $Environment['GIT_LFS_SKIP_SMUDGE'] = '1'
    # Partial clone の不足 object を取得したり replace ref で別 blob へ差し替えたりすると、
    # local-only scan が network / repository write を起こすため、全 Git 子で明示的に無効化する。
    $Environment['GIT_NO_LAZY_FETCH'] = '1'
    $Environment['GIT_NO_REPLACE_OBJECTS'] = '1'

    $safeConfig = @(
        [pscustomobject]@{ Key = 'core.hooksPath'; Value = $hooksDirectory },
        [pscustomobject]@{ Key = 'core.attributesFile'; Value = $emptyAttributes },
        [pscustomobject]@{ Key = 'core.excludesFile'; Value = $emptyExcludes },
        [pscustomobject]@{ Key = 'core.fsmonitor'; Value = 'false' },
        [pscustomobject]@{ Key = 'init.templateDir'; Value = $templateDirectory }
    )
    $Environment['GIT_CONFIG_COUNT'] = [string]$safeConfig.Count
    for ($index = 0; $index -lt $safeConfig.Count; $index++) {
        $Environment["GIT_CONFIG_KEY_$index"] = $safeConfig[$index].Key
        $Environment["GIT_CONFIG_VALUE_$index"] = $safeConfig[$index].Value
    }
}

function Stop-PrivateMarkerPosixProcessGroup {
    param([int]$ProcessGroupId)

    # kill utility の exit 1 では ESRCH と EPERM を区別できない。
    # libc の errno を直接読み、既に消滅した group だけを成功として扱う。
    return [PrivateMarker.PosixSignal]::KillProcessGroup($ProcessGroupId)
}

function Get-PrivateMarkerPosixGateProcessGroupId {
    param([string]$ReadyPath)

    if ([string]::IsNullOrWhiteSpace($ReadyPath) -or
        -not [System.IO.File]::Exists($ReadyPath)) {
        return 0
    }
    try {
        $readyProcessText = [System.IO.File]::ReadAllText(
            $ReadyPath,
            [System.Text.Encoding]::UTF8
        )
        $readyProcessId = 0
        if ([int]::TryParse(
                $readyProcessText,
                [System.Globalization.NumberStyles]::None,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$readyProcessId
            ) -and
            $readyProcessId -gt 0 -and
            [PrivateMarker.PosixSignal]::IsProcessGroupLeader(
                $readyProcessId
            )) {
            return $readyProcessId
        }
    }
    catch {
        # create直後のempty/locked fileは次のbounded pollで再読する。
    }
    return 0
}

function Get-PrivateMarkerPosixGateCompletion {
    param([string]$CompletionPath)

    $incomplete = [pscustomobject]@{
        Completed = $false
        ExitCode = -1
    }
    if ([string]::IsNullOrWhiteSpace($CompletionPath) -or
        -not [System.IO.File]::Exists($CompletionPath)) {
        return $incomplete
    }
    try {
        # wrapperはtemporary fileをatomic renameしてから終了する。fork前の
        # setsid親ではなく、実payloadを所有するwrapperの終了codeを採用する。
        $exitCodeText = [System.IO.File]::ReadAllText(
            $CompletionPath,
            [System.Text.Encoding]::UTF8
        )
        $exitCode = 0
        if ([int]::TryParse(
                $exitCodeText,
                [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$exitCode
            )) {
            return [pscustomobject]@{
                Completed = $true
                ExitCode = $exitCode
            }
        }
    }
    catch {
        # rename直後のfilesystem visibility競合は次のbounded pollで再読する。
    }
    return $incomplete
}

function Stop-PrivateMarkerProcessTree {
    param(
        [System.Diagnostics.Process]$Process = $null,
        [PrivateMarker.ContainedProcess]$ContainedProcess = $null,
        [IntPtr]$JobHandle,
        [int]$PosixProcessGroupId = 0,
        [int]$WaitMilliseconds = 5000
    )

    # operation deadlineとは独立したcleanup専用の総budgetを使う。複数の
    # WaitForExitへ同じ猶予を再利用してcleanup時間を段階数倍へ伸ばさない。
    $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()

    if ($null -ne $ContainedProcess) {
        $jobClosed = $false
        $fallbackTerminationSucceeded = $true
        try {
            $ContainedProcess.CloseJob()
            $jobClosed = $true
        }
        catch {
            $jobClosed = $false
            # Job handleはClose失敗時もContainedProcessが保持する。direct
            # targetを必ず止め、後続Stop/DisposeでJob closeを再試行できる。
            try {
                $ContainedProcess.Terminate()
            }
            catch {
                $fallbackTerminationSucceeded = $false
            }
        }
        if (-not $ContainedProcess.HasExited) {
            $remainingCleanupMilliseconds = [Math]::Max(
                0,
                $WaitMilliseconds -
                    [int]$cleanupClock.ElapsedMilliseconds
            )
            if ($remainingCleanupMilliseconds -gt 0) {
                [void]$ContainedProcess.WaitForExit(
                    $remainingCleanupMilliseconds
                )
            }
        }
        return [pscustomobject]@{
            JobClosed = $jobClosed
            ProcessExited = (
                $fallbackTerminationSucceeded -and
                $ContainedProcess.HasExited
            )
        }
    }

    if ($PosixProcessGroupId -gt 0) {
        $groupStopped =
            Stop-PrivateMarkerPosixProcessGroup `
                -ProcessGroupId $PosixProcessGroupId
        if (-not $Process.HasExited) {
            $remainingCleanupMilliseconds = [Math]::Max(
                0,
                $WaitMilliseconds -
                    [int]$cleanupClock.ElapsedMilliseconds
            )
            if ($remainingCleanupMilliseconds -gt 0) {
                [void]$Process.WaitForExit($remainingCleanupMilliseconds)
            }
        }
        return [pscustomobject]@{
            JobClosed = $false
            # 呼出側の既存契約へ group signal の成否も畳み込み、
            # EPERM 等を TreeStopped=true として誤報しない。
            ProcessExited = $groupStopped -and $Process.HasExited
        }
    }

    $jobClosed = $false
    if ($JobHandle -ne [IntPtr]::Zero) {
        try {
            # KILL_ON_JOB_CLOSE で、親が終了済みでも pipe を持つ孫を停止する。
            [PrivateMarker.ProcessBoundary]::Close($JobHandle)
            $jobClosed = $true
        }
        catch {
            $jobClosed = $false
        }
    }

    if (-not $Process.HasExited) {
        try {
            # stop要求後にoperation budget分をもう一度待たず、tree terminationを
            # 直ちに開始して、残りのcleanup budgetを終了確認へ残す。
            $killTreeMethod =
                $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
            if ($null -ne $killTreeMethod) {
                [void]$killTreeMethod.Invoke($Process, @($true))
            } elseif (Test-PrivateMarkerWindowsHost) {
                $taskkillInfo = New-Object System.Diagnostics.ProcessStartInfo
                $taskkillInfo.FileName =
                    Join-Path $env:SystemRoot 'System32\taskkill.exe'
                $taskkillInfo.Arguments = "/PID $($Process.Id) /T /F"
                $taskkillInfo.UseShellExecute = $false
                $taskkillInfo.CreateNoWindow = $true
                $taskkill = [System.Diagnostics.Process]::Start($taskkillInfo)
                try {
                    $remainingCleanupMilliseconds = [Math]::Max(
                        0,
                        $WaitMilliseconds -
                            [int]$cleanupClock.ElapsedMilliseconds
                    )
                    if ($remainingCleanupMilliseconds -gt 0 -and
                        -not $taskkill.WaitForExit(
                            $remainingCleanupMilliseconds
                        )) {
                        $taskkill.Kill()
                    }
                }
                finally {
                    $taskkill.Dispose()
                }
            } else {
                $Process.Kill()
            }
        }
        catch {
            if (-not $Process.HasExited) {
                try { $Process.Kill() } catch { }
            }
        }
    }
    if (-not $Process.HasExited) {
        $remainingCleanupMilliseconds = [Math]::Max(
            0,
            $WaitMilliseconds -
                [int]$cleanupClock.ElapsedMilliseconds
        )
        if ($remainingCleanupMilliseconds -gt 0) {
            [void]$Process.WaitForExit($remainingCleanupMilliseconds)
        }
    }

    return [pscustomobject]@{
        JobClosed = $jobClosed
        ProcessExited = $Process.HasExited
    }
}

function Wait-PrivateMarkerReadTask {
    param(
        [System.Threading.Tasks.Task]$Task,
        [int]$WaitMilliseconds
    )

    try {
        return $Task.Wait($WaitMilliseconds)
    }
    catch {
        return $false
    }
}

function Get-PrivateMarkerRemainingCleanupWaitMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$CleanupClock,
        [int]$CleanupBudgetMilliseconds
    )

    # Invoke 単位で開始した cleanup clock だけを参照し、複数の kill/wait が
    # それぞれ新しい猶予を得ないよう total budget の残量へ畳む。
    return [Math]::Max(
        0,
        $CleanupBudgetMilliseconds -
            [int]$CleanupClock.ElapsedMilliseconds
    )
}

function Invoke-PrivateMarkerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$Arguments = @(),

        [byte[]]$StandardInputBytes = $null,

        [string]$WorkingDirectory = '',

        [hashtable]$EnvironmentOverrides = @{},

        [switch]$SanitizeGitEnvironment,

        [string]$IsolationRoot = '',

        [int]$TimeoutMilliseconds = 15000,

        [int]$MaximumStandardOutputBytes = 8388608,

        [int]$MaximumStandardErrorBytes = 1048576,

        [int]$MaximumStandardInputBytes = 16777216,

        # production caller の既定猶予は維持し、synthetic pipe fixture だけが
        # 同じ状態遷移を短い期限で検証できるよう lower-only にする。
        [ValidateRange(100, 2000)]
        [int]$StreamCompletionWaitMilliseconds = 250,

        [ValidateRange(250, 5000)]
        [int]$StreamCleanupWaitMilliseconds = 5000,

        # self-test専用。Job割当前/Resume前のfailureでもsuspended targetを
        # 実行せず、terminate/close/waitをboundedに完了させる。
        [ValidateSet('', 'assign', 'resume')]
        [string]$ForceWindowsLaunchFailure = '',

        # self-test専用。最初のJob closeだけを失敗させ、handle保持、
        # direct TerminateProcess fallback、次回close retryを実測する。
        [ValidateSet('', 'once')]
        [string]$ForceWindowsJobCloseFailure = '',

        # /usr/bin/setsid が無いPOSIX host向けnative gateをself-testで
        # 強制し、portable fallbackも同じcontainment契約で検証する。
        [switch]$ForceNativePosixSessionGate,

        # self-test専用。BusyBox互換shimを実行し、external setsidの
        # portable operandとready-PID handshakeを実測する。
        [string]$PosixSetsidExecutableOverride = ''
    )

    if ($SanitizeGitEnvironment -and [string]::IsNullOrWhiteSpace($IsolationRoot)) {
        throw 'IsolationRoot is required when SanitizeGitEnvironment is used.'
    }
    if ($null -ne $StandardInputBytes -and
        $StandardInputBytes.Length -gt $MaximumStandardInputBytes) {
        throw 'Standard input exceeds the bounded process byte limit.'
    }

    $process = $null
    $containedProcess = $null
    $processStarted = $false
    $containmentEstablished = $false
    $posixProcessGroupId = 0
    $posixGateReadyPath = $null
    $posixGateReleasePath = $null
    $posixGateCompletionPath = $null
    $posixGateCompletionTempPath = $null
    $posixGateCompleted = $false
    $posixGateExitCode = -1
    $stdinStream = $null
    $stdoutStream = $null
    $stderrStream = $null
    $stdinTask = $null
    $stdinClosed = $false
    $inputWriteFailed = $false
    $stdoutTask = $null
    $stderrTask = $null
    $timedOut = $false
    $outputLimitExceeded = $false
    $pipeLeakDetected = $false
    $treeStopped = $true
    $exitCode = -1
    $stdoutBytes = New-Object byte[] 0
    $stderrBytes = New-Object byte[] 0
    # preparation/start/handshakeもcaller timeoutへ含める。cleanupはこの
    # deadlineを再利用せず、別の有限猶予で必ず回収を試みる。
    $operationClock = [System.Diagnostics.Stopwatch]::StartNew()
    $processCleanupWaitMilliseconds = 5000
    $cleanupBudgetMilliseconds = [Math]::Max(
        $processCleanupWaitMilliseconds,
        $StreamCleanupWaitMilliseconds
    )
    $cleanupClock = $null

    try {
        # 子へ渡す environment は親 process の clone から作り、親自身は変更しない。
        $childEnvironment = @{}
        $processEnvironment = [Environment]::GetEnvironmentVariables('Process')
        foreach ($name in $processEnvironment.Keys) {
            $childEnvironment["$name"] = [string]$processEnvironment[$name]
        }
        if ($SanitizeGitEnvironment) {
            Set-PrivateMarkerHermeticGitEnvironment `
                -Environment $childEnvironment `
                -IsolationRoot $IsolationRoot
        }
        foreach ($name in $EnvironmentOverrides.Keys) {
            # `$null` は child だけの unset を表す。ambient OS 判定などの
            # absent / present-empty / forged 値を親環境へ触れず検証できる。
            if ($null -eq $EnvironmentOverrides[$name]) {
                [void]$childEnvironment.Remove("$name")
            } else {
                $childEnvironment["$name"] =
                    [string]$EnvironmentOverrides[$name]
            }
        }

        if (Test-PrivateMarkerWindowsHost) {
            if ($operationClock.ElapsedMilliseconds -ge
                $TimeoutMilliseconds) {
                throw 'Bounded child deadline expired before process launch.'
            }
            $remainingLaunchMilliseconds = [Math]::Max(
                1,
                $TimeoutMilliseconds -
                    [int]$operationClock.ElapsedMilliseconds
            )
            try {
                # Direct target を suspended で作り、Job assign 後だけ resume する。
                $containedProcess = [PrivateMarker.ContainedProcess]::Start(
                    $FileName,
                    [string[]]$Arguments,
                    $childEnvironment,
                    $WorkingDirectory,
                    $ForceWindowsLaunchFailure,
                    $ForceWindowsJobCloseFailure,
                    $remainingLaunchMilliseconds
                )
            }
            catch {
                throw "Failed to start atomically contained child process: $($_.Exception.Message)"
            }
            $stdinStream = $containedProcess.StandardInput
            $stdoutStream = $containedProcess.StandardOutput
            $stderrStream = $containedProcess.StandardError
            $processStarted = $true
            $containmentEstablished = $true
        } else {
            $effectiveFileName = $FileName
            $effectiveArguments = @($Arguments)
            $useNativePosixSessionGate = $false
            $setsidPath = $null
            if (-not $ForceNativePosixSessionGate) {
                if (-not [string]::IsNullOrWhiteSpace(
                        $PosixSetsidExecutableOverride
                    )) {
                    if (-not [System.IO.Path]::IsPathRooted(
                            $PosixSetsidExecutableOverride
                        ) -or
                        -not (Test-Path `
                            -LiteralPath $PosixSetsidExecutableOverride `
                            -PathType Leaf)) {
                        throw 'POSIX setsid override must be an existing absolute file.'
                    }
                    $setsidPath = [System.IO.Path]::GetFullPath(
                        $PosixSetsidExecutableOverride
                    )
                } else {
                    $setsidPath = @('/usr/bin/setsid', '/bin/setsid') |
                        Where-Object {
                            Test-Path -LiteralPath $_ -PathType Leaf
                        } |
                        Select-Object -First 1
                }
            }
            if ($ForceNativePosixSessionGate -or
                [string]::IsNullOrWhiteSpace($setsidPath)) {
                # macOS等でsetsid executableが無い場合はwrapper自身が
                # setsid(2)を先に実行する。
                $useNativePosixSessionGate = $true
            }

            # external setsid / native setsidのどちらも、session確立後の
            # child PIDをready fileで返す。同じPIDがPGIDであることを親が
            # kernelへ確認するまでpayloadをreleaseしない。
            $gateRoot = if ([string]::IsNullOrWhiteSpace($IsolationRoot)) {
                [System.IO.Path]::GetTempPath()
            } else {
                $IsolationRoot
            }
            if (-not (Test-Path -LiteralPath $gateRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $gateRoot -Force |
                    Out-Null
            }
            $gateId = [Guid]::NewGuid().ToString('N')
            $posixGateReadyPath =
                Join-Path $gateRoot "private-marker-posix-ready-$gateId"
            $posixGateReleasePath =
                Join-Path $gateRoot "private-marker-posix-release-$gateId"
            $posixGateCompletionPath =
                Join-Path $gateRoot "private-marker-posix-complete-$gateId"
            $payloadJson = [pscustomobject]@{
                FileName = $FileName
                Arguments = @($Arguments)
            } | ConvertTo-Json -Compress -Depth 4
            $payloadBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
            )
            $readyPathBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($posixGateReadyPath)
            )
            $releasePathBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($posixGateReleasePath)
            )
            $completionPathBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes(
                    $posixGateCompletionPath
                )
            )
            $posixWrapperTemplate = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (__CREATE_SESSION__) {
    if ($null -eq ('PrivateMarker.NativePosixSession' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;

namespace PrivateMarker
{
    public static class NativePosixSession
    {
        [DllImport("libc", SetLastError = true)]
        private static extern int setsid();

        public static int Create()
        {
            return setsid();
        }
    }
}
"@
    }
}
$readyPath = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('__READY_PATH__')
)
$releasePath = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('__RELEASE_PATH__')
)
$completionPath = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('__COMPLETION_PATH__')
)
$released = $false
$wrapperExitCode = 127
try {
    if (__CREATE_SESSION__) {
        if ([PrivateMarker.NativePosixSession]::Create() -lt 0) {
            [Console]::Error.WriteLine('Bounded POSIX session setup failed.')
            exit 126
        }
    }
    [IO.File]::WriteAllText(
        $readyPath,
        [Diagnostics.Process]::GetCurrentProcess().Id.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ),
        [Text.UTF8Encoding]::new($false)
    )
    for ($gateAttempt = 0; $gateAttempt -lt 3000; $gateAttempt++) {
        if ([IO.File]::Exists($releasePath)) {
            $released = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if (-not $released) {
        exit 124
    }
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__PAYLOAD__')
    )
    $payload = ConvertFrom-Json -InputObject $payloadJson
    $invokeArguments = @($payload.Arguments | ForEach-Object { [string]$_ })
    & ([string]$payload.FileName) @invokeArguments
    $childExitCode = $LASTEXITCODE
    if ($null -eq $childExitCode) {
        $childExitCode = 0
    }
    $wrapperExitCode = [int]$childExitCode
}
catch {
    [Console]::Error.WriteLine('Bounded child launch failed.')
    $wrapperExitCode = 127
}
if ($released) {
    try {
        $completionTempPath = (
            $completionPath + '.' +
            [Diagnostics.Process]::GetCurrentProcess().Id.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            ) +
            '.tmp'
        )
        [IO.File]::WriteAllText(
            $completionTempPath,
            $wrapperExitCode.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            ),
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::Move($completionTempPath, $completionPath)
    }
    catch {
        [Console]::Error.WriteLine('Bounded child completion failed.')
        $wrapperExitCode = 127
    }
}
exit $wrapperExitCode
'@
            $createSessionLiteral = if ($useNativePosixSessionGate) {
                '$true'
            } else {
                '$false'
            }
            $posixWrapperScript = $posixWrapperTemplate.Replace(
                '__CREATE_SESSION__',
                $createSessionLiteral
            ).Replace(
                '__READY_PATH__',
                $readyPathBase64
            ).Replace(
                '__RELEASE_PATH__',
                $releasePathBase64
            ).Replace(
                '__COMPLETION_PATH__',
                $completionPathBase64
            ).Replace(
                '__PAYLOAD__',
                $payloadBase64
            )
            $posixWrapperBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes(
                    $posixWrapperScript
                )
            )
            $currentPowerShellExecutable = (
                [System.Diagnostics.Process]::GetCurrentProcess()
            ).MainModule.FileName
            if ($useNativePosixSessionGate) {
                $effectiveFileName = $currentPowerShellExecutable
                $effectiveArguments = @(
                    '-NoProfile',
                    '-EncodedCommand',
                    $posixWrapperBase64
                )
            } else {
                # optionを使わないportable operandでwrapperを起動する。
                # ready PIDをgetpgidで再確認するため、shimやsetsid実装差でも
                # Process.StartのPIDをPGIDと推測しない。
                $effectiveFileName = $setsidPath
                $effectiveArguments =
                    Get-PrivateMarkerPosixSetsidArguments `
                        -PowerShellExecutable $currentPowerShellExecutable `
                        -EncodedCommand $posixWrapperBase64
            }

            if ($operationClock.ElapsedMilliseconds -ge
                $TimeoutMilliseconds) {
                throw 'Bounded child deadline expired before process launch.'
            }
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $effectiveFileName
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            if ($null -ne
                $startInfo.PSObject.Properties['StandardInputEncoding']) {
                # BaseStreamへraw bytesを書込む前にStreamWriterが生成する
                # preambleをBOM-lessへ固定し、native Git protocolを汚染しない。
                $startInfo.StandardInputEncoding =
                    [System.Text.UTF8Encoding]::new($false)
            }
            if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
                $startInfo.WorkingDirectory = $WorkingDirectory
            }
            $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
            if ($null -ne $argumentListProperty) {
                foreach ($argument in $effectiveArguments) {
                    $startInfo.ArgumentList.Add($argument)
                }
            } else {
                $startInfo.Arguments = (
                    $effectiveArguments | ForEach-Object {
                        ConvertTo-PrivateMarkerProcessArgument -Argument $_
                    }
                ) -join ' '
            }
            $startInfo.EnvironmentVariables.Clear()
            foreach ($name in $childEnvironment.Keys) {
                $startInfo.EnvironmentVariables["$name"] =
                    [string]$childEnvironment[$name]
            }

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            if ($operationClock.ElapsedMilliseconds -ge
                $TimeoutMilliseconds) {
                throw 'Bounded child deadline expired before process launch.'
            }
            $processStarted = $process.Start()
            if (-not $processStarted) {
                throw "Failed to start bounded child process: $FileName"
            }
            $posixGateReady = $false
            $readyProcessId = 0
            for ($gateAttempt = 0;
                $gateAttempt -lt 2000 -and
                $operationClock.ElapsedMilliseconds -lt
                    $TimeoutMilliseconds;
                $gateAttempt++) {
                $readyProcessId =
                    Get-PrivateMarkerPosixGateProcessGroupId `
                        -ReadyPath $posixGateReadyPath
                if ($readyProcessId -gt 0) {
                    $posixGateReady = $true
                    break
                }
                # external setsidが実装上forkする場合はProcess.Startのchildが
                # 先に終了し得る。ready PIDをdeadlineまで待ってPGIDを確定する。
                $gateRemainingMilliseconds = [Math]::Max(
                    1,
                    $TimeoutMilliseconds -
                        [int]$operationClock.ElapsedMilliseconds
                )
                Start-Sleep -Milliseconds (
                    [Math]::Min(5, $gateRemainingMilliseconds)
                )
            }
            if (-not $posixGateReady) {
                # deadline境界でreadyがrename/write済みになる競合を一度だけ再確認する。
                $readyProcessId =
                    Get-PrivateMarkerPosixGateProcessGroupId `
                        -ReadyPath $posixGateReadyPath
                $posixGateReady = $readyProcessId -gt 0
            }
            if ($posixGateReady) {
                # release可否に関係なく、検証済みPGIDを先に保持してcleanup先を固定する。
                $posixProcessGroupId = $readyProcessId
                $posixGateCompletionTempPath = (
                    $posixGateCompletionPath + '.' +
                    $posixProcessGroupId.ToString(
                        [System.Globalization.CultureInfo]::InvariantCulture
                    ) +
                    '.tmp'
                )
            }
            if (-not $posixGateReady -or
                $operationClock.ElapsedMilliseconds -ge
                    $TimeoutMilliseconds) {
                if ($null -eq $cleanupClock) {
                    $cleanupClock =
                        [System.Diagnostics.Stopwatch]::StartNew()
                }
                $remainingCleanupMilliseconds = [Math]::Max(
                    0,
                    $cleanupBudgetMilliseconds -
                        [int]$cleanupClock.ElapsedMilliseconds
                )
                if ($posixProcessGroupId -gt 0) {
                    [void](Stop-PrivateMarkerProcessTree `
                            -Process $process `
                            -PosixProcessGroupId $posixProcessGroupId `
                            -WaitMilliseconds $remainingCleanupMilliseconds)
                } else {
                    # group未確認ならtracked treeを直ちに止める。external setsidが
                    # fork済みで親だけ終了した場合は、独立cleanup猶予内でlate
                    # ready PIDを回収し、未release groupへsignalする。
                    [void](Stop-PrivateMarkerProcessTree `
                            -Process $process `
                            -WaitMilliseconds $remainingCleanupMilliseconds)
                    if (-not $useNativePosixSessionGate) {
                        for ($cleanupAttempt = 0;
                            $cleanupAttempt -lt 1000 -and
                            $cleanupClock.ElapsedMilliseconds -lt
                                $cleanupBudgetMilliseconds;
                            $cleanupAttempt++) {
                            $lateProcessGroupId =
                                Get-PrivateMarkerPosixGateProcessGroupId `
                                    -ReadyPath $posixGateReadyPath
                            if ($lateProcessGroupId -gt 0) {
                                $posixProcessGroupId = $lateProcessGroupId
                                $posixGateCompletionTempPath = (
                                    $posixGateCompletionPath + '.' +
                                    $posixProcessGroupId.ToString(
                                        [System.Globalization.CultureInfo]::InvariantCulture
                                    ) +
                                    '.tmp'
                                )
                                $remainingGateCleanupMilliseconds =
                                    [Math]::Max(
                                        0,
                                        $cleanupBudgetMilliseconds -
                                            [int]$cleanupClock.ElapsedMilliseconds
                                    )
                                [void](Stop-PrivateMarkerProcessTree `
                                        -Process $process `
                                        -PosixProcessGroupId `
                                            $posixProcessGroupId `
                                        -WaitMilliseconds `
                                            $remainingGateCleanupMilliseconds)
                                break
                            }
                            $remainingGateCleanupMilliseconds =
                                [Math]::Max(
                                    1,
                                    $cleanupBudgetMilliseconds -
                                        [int]$cleanupClock.ElapsedMilliseconds
                                )
                            Start-Sleep -Milliseconds (
                                [Math]::Min(
                                    5,
                                    $remainingGateCleanupMilliseconds
                                )
                            )
                        }
                    }
                }
                throw 'Failed to establish the bounded POSIX session gate.'
            }
            # ready PIDが実PGIDであることを確認してからreleaseするため、
            # targetの最初の命令より先にcleanup先が確定する。
            $containmentEstablished = $true
            try {
                [System.IO.File]::WriteAllText(
                    $posixGateReleasePath,
                    'release',
                    [System.Text.UTF8Encoding]::new($false)
                )
            }
            catch {
                if ($null -eq $cleanupClock) {
                    $cleanupClock =
                        [System.Diagnostics.Stopwatch]::StartNew()
                }
                $remainingCleanupMilliseconds =
                    Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                        -CleanupClock $cleanupClock `
                        -CleanupBudgetMilliseconds `
                            $cleanupBudgetMilliseconds
                [void](Stop-PrivateMarkerProcessTree `
                        -Process $process `
                        -PosixProcessGroupId $posixProcessGroupId `
                        -WaitMilliseconds $remainingCleanupMilliseconds)
                throw
            }
            $stdinStream = $process.StandardInput.BaseStream
            $stdoutStream = $process.StandardOutput.BaseStream
            $stderrStream = $process.StandardError.BaseStream
        }

        $stdoutTask = [PrivateMarker.BoundedStreamReader]::ReadAsync(
            $stdoutStream,
            $MaximumStandardOutputBytes
        )
        $stderrTask = [PrivateMarker.BoundedStreamReader]::ReadAsync(
            $stderrStream,
            $MaximumStandardErrorBytes
        )

        $effectiveInputBytes = if ($null -eq $StandardInputBytes) {
            New-Object byte[] 0
        } else {
            $StandardInputBytes
        }
        if ($effectiveInputBytes.Length -eq 0) {
            $stdinStream.Dispose()
            $stdinClosed = $true
        } else {
            $stdinTask = $stdinStream.WriteAsync(
                $effectiveInputBytes,
                0,
                $effectiveInputBytes.Length
            )
        }
        $processHasExited = if ($null -ne $containedProcess) {
            $containedProcess.HasExited
        } elseif ($posixProcessGroupId -gt 0) {
            $posixCompletion = Get-PrivateMarkerPosixGateCompletion `
                -CompletionPath $posixGateCompletionPath
            if ($posixCompletion.Completed) {
                $posixGateCompleted = $true
                $posixGateExitCode = $posixCompletion.ExitCode
            }
            $posixGateCompleted
        } else {
            $process.HasExited
        }
        while (-not $processHasExited -and
            $operationClock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if (-not $stdinClosed -and
                $null -ne $stdinTask -and
                $stdinTask.IsCompleted) {
                if ($stdinTask.IsFaulted -or $stdinTask.IsCanceled) {
                    $inputWriteFailed = $true
                } else {
                    try {
                        $stdinStream.Dispose()
                    }
                    catch {
                        $inputWriteFailed = $true
                    }
                }
                $stdinClosed = $true
            }
            if (($stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stdoutTask.Result.LimitExceeded) -or
                ($stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stderrTask.Result.LimitExceeded) -or
                $inputWriteFailed -or
                $stdoutTask.IsFaulted -or
                $stderrTask.IsFaulted) {
                $outputLimitExceeded = $stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stdoutTask.Result.LimitExceeded
                $outputLimitExceeded = $outputLimitExceeded -or (
                    $stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stderrTask.Result.LimitExceeded
                )
                break
            }
            $operationWaitMilliseconds = [Math]::Min(
                100,
                [Math]::Max(
                    1,
                    $TimeoutMilliseconds -
                        [int]$operationClock.ElapsedMilliseconds
                )
            )
            if ($null -ne $containedProcess) {
                [void]$containedProcess.WaitForExit($operationWaitMilliseconds)
            } elseif ($posixProcessGroupId -gt 0) {
                # external setsidがforkした後はtracked親が終了済みでも、
                # wrapper completion fileを待つ。busy pollでdeadlineを消費しない。
                if (-not $process.HasExited) {
                    [void]$process.WaitForExit($operationWaitMilliseconds)
                } else {
                    Start-Sleep -Milliseconds $operationWaitMilliseconds
                }
            } else {
                [void]$process.WaitForExit($operationWaitMilliseconds)
            }
            $processHasExited = if ($null -ne $containedProcess) {
                $containedProcess.HasExited
            } elseif ($posixProcessGroupId -gt 0) {
                $posixCompletion = Get-PrivateMarkerPosixGateCompletion `
                    -CompletionPath $posixGateCompletionPath
                if ($posixCompletion.Completed) {
                    $posixGateCompleted = $true
                    $posixGateExitCode = $posixCompletion.ExitCode
                }
                $posixGateCompleted
            } else {
                $process.HasExited
            }
        }

        if (-not $stdinClosed) {
            if ($null -ne $stdinTask -and
                $stdinTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                try {
                    $stdinStream.Dispose()
                }
                catch {
                    $inputWriteFailed = $true
                }
            } elseif ($operationClock.ElapsedMilliseconds -lt
                $TimeoutMilliseconds) {
                $inputWriteFailed = $true
            }
            $stdinClosed = $true
        }

        $processHasExited = if ($null -ne $containedProcess) {
            $containedProcess.HasExited
        } elseif ($posixProcessGroupId -gt 0) {
            $posixCompletion = Get-PrivateMarkerPosixGateCompletion `
                -CompletionPath $posixGateCompletionPath
            if ($posixCompletion.Completed) {
                $posixGateCompleted = $true
                $posixGateExitCode = $posixCompletion.ExitCode
            }
            $posixGateCompleted
        } else {
            $process.HasExited
        }
        if (-not $processHasExited -and
            $operationClock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            $timedOut = $true
        }

        $needsTreeStop = $timedOut -or
            $outputLimitExceeded -or
            $inputWriteFailed -or
            $stdoutTask.IsFaulted -or
            $stderrTask.IsFaulted
        if ($needsTreeStop) {
            if ($null -eq $cleanupClock) {
                $cleanupClock =
                    [System.Diagnostics.Stopwatch]::StartNew()
            }
            $remainingCleanupMilliseconds =
                Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                    -CleanupClock $cleanupClock `
                    -CleanupBudgetMilliseconds $cleanupBudgetMilliseconds
            $stopResult = Stop-PrivateMarkerProcessTree `
                -Process $process `
                -ContainedProcess $containedProcess `
                -JobHandle ([IntPtr]::Zero) `
                -PosixProcessGroupId $posixProcessGroupId `
                -WaitMilliseconds $remainingCleanupMilliseconds
            $treeStopped = $stopResult.ProcessExited -and (
                -not (Test-PrivateMarkerWindowsHost) -or $stopResult.JobClosed
            )
        }

        $processHasExited = if ($null -ne $containedProcess) {
            $containedProcess.HasExited
        } elseif ($posixProcessGroupId -gt 0) {
            $posixGateCompleted
        } else {
            $process.HasExited
        }
        if ($processHasExited) {
            $exitCode = if ($null -ne $containedProcess) {
                $containedProcess.ExitCode
            } elseif ($posixProcessGroupId -gt 0) {
                $posixGateExitCode
            } else {
                $process.ExitCode
            }
        }

        # 親が正常終了しても、孫が pipe handle を保持すれば read task は終わらない。
        $stdoutCompletionWaitMilliseconds =
            $StreamCompletionWaitMilliseconds
        if ($null -ne $cleanupClock) {
            $stdoutCompletionWaitMilliseconds = [Math]::Min(
                $StreamCompletionWaitMilliseconds,
                (Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                    -CleanupClock $cleanupClock `
                    -CleanupBudgetMilliseconds $cleanupBudgetMilliseconds)
            )
        }
        $stdoutInitiallyComplete = Wait-PrivateMarkerReadTask `
            -Task $stdoutTask `
            -WaitMilliseconds $stdoutCompletionWaitMilliseconds
        if (-not $stdoutInitiallyComplete -and $null -eq $cleanupClock) {
            $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()
        }
        $stderrCompletionWaitMilliseconds =
            $StreamCompletionWaitMilliseconds
        if ($null -ne $cleanupClock) {
            $stderrCompletionWaitMilliseconds = [Math]::Min(
                $StreamCompletionWaitMilliseconds,
                (Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                    -CleanupClock $cleanupClock `
                    -CleanupBudgetMilliseconds $cleanupBudgetMilliseconds)
            )
        }
        $stderrInitiallyComplete = Wait-PrivateMarkerReadTask `
            -Task $stderrTask `
            -WaitMilliseconds $stderrCompletionWaitMilliseconds
        if (-not $stdoutInitiallyComplete -or -not $stderrInitiallyComplete) {
            $pipeLeakDetected = $true
            if ($null -eq $cleanupClock) {
                $cleanupClock =
                    [System.Diagnostics.Stopwatch]::StartNew()
            }
            $processHasExited = if ($null -ne $containedProcess) {
                $containedProcess.HasExited
            } else {
                $process.HasExited
            }
            if ($null -ne $containedProcess -or
                $posixProcessGroupId -gt 0 -or
                -not $processHasExited) {
                $remainingCleanupMilliseconds =
                    Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                        -CleanupClock $cleanupClock `
                        -CleanupBudgetMilliseconds `
                            $cleanupBudgetMilliseconds
                $stopResult = Stop-PrivateMarkerProcessTree `
                    -Process $process `
                    -ContainedProcess $containedProcess `
                    -JobHandle ([IntPtr]::Zero) `
                    -PosixProcessGroupId $posixProcessGroupId `
                    -WaitMilliseconds $remainingCleanupMilliseconds
                $treeStopped = $treeStopped -and
                    $stopResult.ProcessExited -and (
                        -not (Test-PrivateMarkerWindowsHost) -or $stopResult.JobClosed
                    )
            } elseif (Test-PrivateMarkerWindowsHost) {
                $treeStopped = $false
            }
            $stdoutCleanupWaitMilliseconds = [Math]::Min(
                $StreamCleanupWaitMilliseconds,
                (Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                    -CleanupClock $cleanupClock `
                    -CleanupBudgetMilliseconds $cleanupBudgetMilliseconds)
            )
            [void](Wait-PrivateMarkerReadTask `
                    -Task $stdoutTask `
                    -WaitMilliseconds $stdoutCleanupWaitMilliseconds)
            $stderrCleanupWaitMilliseconds = [Math]::Min(
                $StreamCleanupWaitMilliseconds,
                (Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                    -CleanupClock $cleanupClock `
                    -CleanupBudgetMilliseconds $cleanupBudgetMilliseconds)
            )
            [void](Wait-PrivateMarkerReadTask `
                    -Task $stderrTask `
                    -WaitMilliseconds $stderrCleanupWaitMilliseconds)
        }

        if ($stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $stdoutBytes = $stdoutTask.Result.Data
            $outputLimitExceeded = $outputLimitExceeded -or $stdoutTask.Result.LimitExceeded
        }
        if ($stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $stderrBytes = $stderrTask.Result.Data
            $outputLimitExceeded = $outputLimitExceeded -or $stderrTask.Result.LimitExceeded
        }
    }
    finally {
        if ($processStarted) {
            if ($null -eq $cleanupClock) {
                $cleanupClock =
                    [System.Diagnostics.Stopwatch]::StartNew()
            }
            $remainingCleanupMilliseconds =
                Get-PrivateMarkerRemainingCleanupWaitMilliseconds `
                    -CleanupClock $cleanupClock `
                    -CleanupBudgetMilliseconds $cleanupBudgetMilliseconds
            if ($null -ne $containedProcess) {
                $stopResult = Stop-PrivateMarkerProcessTree `
                    -Process $process `
                    -ContainedProcess $containedProcess `
                    -JobHandle ([IntPtr]::Zero) `
                    -PosixProcessGroupId 0 `
                    -WaitMilliseconds $remainingCleanupMilliseconds
                $treeStopped = $treeStopped -and
                    $stopResult.ProcessExited -and (
                        $stopResult.JobClosed
                    )
            } elseif ($null -ne $process -and
                $posixProcessGroupId -gt 0) {
                # direct childが先に終了してもgroupは孫を指し続ける。
                # finallyで必ずsignalし、pipeを持たない孫の副作用も止める。
                $stopResult = Stop-PrivateMarkerProcessTree `
                    -Process $process `
                    -ContainedProcess $null `
                    -JobHandle ([IntPtr]::Zero) `
                    -PosixProcessGroupId $posixProcessGroupId `
                    -WaitMilliseconds $remainingCleanupMilliseconds
                $treeStopped = $treeStopped -and
                    $stopResult.ProcessExited
            } elseif ($null -ne $process -and -not $process.HasExited) {
                $stopResult = Stop-PrivateMarkerProcessTree `
                    -Process $process `
                    -ContainedProcess $null `
                    -JobHandle ([IntPtr]::Zero) `
                    -PosixProcessGroupId 0 `
                    -WaitMilliseconds $remainingCleanupMilliseconds
                $treeStopped = $treeStopped -and $stopResult.ProcessExited
            }
        }
        if (-not $stdinClosed -and $null -ne $stdinStream) {
            try {
                $stdinStream.Dispose()
            }
            catch {
                $inputWriteFailed = $true
            }
            $stdinClosed = $true
        }
        if ($null -ne $containedProcess) {
            $containedProcess.Dispose()
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
        foreach ($gatePath in @(
            $posixGateReadyPath,
            $posixGateReleasePath,
            $posixGateCompletionPath,
            $posixGateCompletionTempPath
        )) {
            if (-not [string]::IsNullOrWhiteSpace($gatePath)) {
                try {
                    [System.IO.File]::Delete($gatePath)
                }
                catch {
                    # cleanup artifact失敗はprocess tree判定へ影響させない。
                }
            }
        }
    }

    $streamsCompleted = $null -ne $stdoutTask -and
        $null -ne $stderrTask -and
        $stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
        $stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
        -not $pipeLeakDetected

    return [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutputBytes = $stdoutBytes
        StandardErrorBytes = $stderrBytes
        TimedOut = $timedOut
        OutputLimitExceeded = $outputLimitExceeded
        InputWriteFailed = $inputWriteFailed
        PipeLeakDetected = $pipeLeakDetected
        StreamsCompleted = $streamsCompleted
        TreeStopped = $treeStopped
        ContainmentEstablished = $containmentEstablished
    }
}

function ConvertFrom-PrivateMarkerUtf8Bytes {
    param(
        [byte[]]$Bytes,
        [string]$Context
    )

    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            return $text.Substring(1)
        }
        return $text
    }
    catch [System.Text.DecoderFallbackException] {
        throw "$Context is not valid UTF-8."
    }
}
