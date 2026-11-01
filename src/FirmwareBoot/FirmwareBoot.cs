// .NET Framework 4 / AnyCPU. Production writes are restricted to ARM64 UEFI WinPE.
// UEFI 2.11 3.1.3 and UEFI 2.10 10.3.5.1/10.3.5.4 define the byte layouts below.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace ArmBootRepair
{
    public static class FirmwareBoot
    {
        internal const uint StandardAttributes = 7; // NV | BS | RT
        internal const int MaximumVariableBytes = 131072;
        internal const string ManagerPath = "\\EFI\\Microsoft\\Boot\\bootmgfw.efi";
        internal const string Description = "Windows Boot Manager - Windows ARM repair";

        public static string SelfTest()
        {
            byte[] option = BuildLoadOption(new Guid("00112233-4455-6677-8899-aabbccddeeff"), 1, 1048576, 536870912, 512);
            int node = 6 + Encoding.Unicode.GetByteCount(Description + "\0");
            if (Read32(option, 0) != 1 || option[node] != 4 || option[node + 1] != 1 || Read16(option, node + 2) != 42 ||
                Read32(option, node + 4) != 1 || Read64(option, node + 8) != 2048 || Read64(option, node + 16) != 1048576 ||
                option[node + 40] != 2 || option[node + 41] != 2 || option[option.Length - 4] != 0x7f || option[option.Length - 3] != 0xff ||
                Read16(option, 4) != option.Length - node)
                throw new InvalidOperationException("UEFI load-option codec self-test failed.");
            byte[] guid = new Guid("00112233-4455-6677-8899-aabbccddeeff").ToByteArray();
            for (int i = 0; i < guid.Length; i++) if (option[node + 24 + i] != guid[i]) throw new InvalidOperationException("GPT GUID byte order failed.");
            return "PASS: GPT HD/FilePath/EFI_LOAD_OPTION codec; no firmware access.";
        }

        public static string Probe()
        {
            GuardEnvironment();
            using (PrivilegeScope privilege = new PrivilegeScope())
            {
                NativeVariables variables = new NativeVariables();
                VariableState order = variables.Read("BootOrder");
                VariableState next = variables.Read("BootNext");
                ValidateOrder(order); ValidateNext(next);
                return "UEFI variable access verified: BootOrder=" + (order.Exists ? order.Data.Length.ToString(CultureInfo.InvariantCulture) + " bytes" : "absent") +
                       "; BootNext=" + (next.Exists ? "present" : "absent") + ".";
            }
        }

        public static string Repair(string espRoot, string partitionGuid, uint partitionNumber,
            long offsetBytes, long sizeBytes, uint logicalSectorSize, string backupDirectory)
        {
            GuardEnvironment();
            if (espRoot == null || espRoot.Length != 3 || espRoot[1] != ':' || espRoot[2] != '\\' ||
                !Char.IsLetter(espRoot[0]) || Char.ToUpperInvariant(espRoot[0]) == 'X')
                throw new ArgumentException("Expected a mounted internal EFI partition root such as S:\\.");
            if (!File.Exists(espRoot + ManagerPath.Substring(1))) throw new FileNotFoundException("Verified EFI Windows Boot Manager is missing.");
            string fullBackup = Path.GetFullPath(backupDirectory);
            if (!Path.IsPathRooted(backupDirectory) || String.Equals(Path.GetPathRoot(fullBackup), espRoot, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Firmware backup must be an absolute directory outside the EFI partition.");
            byte[] option = BuildLoadOption(new Guid(partitionGuid), partitionNumber, offsetBytes, sizeBytes, logicalSectorSize);
            using (PrivilegeScope privilege = new PrivilegeScope())
            {
                return RepairCore(new NativeVariables(), option, fullBackup);
            }
        }

        internal static byte[] BuildLoadOption(Guid partitionGuid, uint partitionNumber, long offsetBytes, long sizeBytes, uint sectorSize)
        {
            if (partitionGuid == Guid.Empty || partitionNumber == 0 || partitionNumber > 1024 ||
                (sectorSize != 512 && sectorSize != 4096) || offsetBytes <= 0 || sizeBytes < 64L * 1024 * 1024 || sizeBytes > 4L * 1024 * 1024 * 1024 ||
                offsetBytes % sectorSize != 0 || sizeBytes % sectorSize != 0)
                throw new ArgumentException("Invalid GPT EFI partition geometry.");
            byte[] path = Encoding.Unicode.GetBytes(ManagerPath + "\0");
            byte[] description = Encoding.Unicode.GetBytes(Description + "\0");
            int listLength = 42 + 4 + path.Length + 4;
            using (MemoryStream stream = new MemoryStream())
            using (BinaryWriter writer = new BinaryWriter(stream))
            {
                writer.Write((uint)1); writer.Write((ushort)listLength); writer.Write(description);
                writer.Write((byte)4); writer.Write((byte)1); writer.Write((ushort)42);
                writer.Write(partitionNumber); writer.Write((ulong)(offsetBytes / sectorSize)); writer.Write((ulong)(sizeBytes / sectorSize));
                writer.Write(partitionGuid.ToByteArray()); writer.Write((byte)2); writer.Write((byte)2);
                writer.Write((byte)4); writer.Write((byte)4); writer.Write((ushort)(4 + path.Length)); writer.Write(path);
                writer.Write((byte)0x7f); writer.Write((byte)0xff); writer.Write((ushort)4);
                return stream.ToArray();
            }
        }

        internal static string RepairCore(IVariables variables, byte[] option, string backupDirectory)
        {
            VariableState oldOrder = variables.Read("BootOrder");
            VariableState oldNext = variables.Read("BootNext");
            ValidateOrder(oldOrder); ValidateNext(oldNext);
            List<ushort> order = DecodeOrder(oldOrder);
            ushort chosen = 0; bool found = false;
            VariableState oldOption = null;
            List<ushort> candidates = new List<ushort>(order);
            if (oldNext.Exists && !candidates.Contains(Read16(oldNext.Data, 0))) candidates.Add(Read16(oldNext.Data, 0));
            HashSet<ushort> inspected = new HashSet<ushort>();
            foreach (ushort number in candidates)
            {
                if (!inspected.Add(number)) continue;
                VariableState candidate = variables.Read(BootName(number));
                if (candidate.Exists && candidate.Attributes == StandardAttributes && EqualBytes(candidate.Data, option))
                { chosen = number; found = true; oldOption = candidate; break; }
            }
            if (!found)
            {
                // Query rather than overwrite: a Boot#### may exist without appearing in BootOrder.
                for (int step = 0; step <= UInt16.MaxValue; step++)
                {
                    ushort number = (ushort)((0x1000 + step) & 0xffff);
                    if (order.Contains(number) || (oldNext.Exists && Read16(oldNext.Data, 0) == number)) continue;
                    VariableState candidate = variables.Read(BootName(number));
                    if (!candidate.Exists) { chosen = number; oldOption = candidate; found = true; break; }
                    if (candidate.Attributes == StandardAttributes && EqualBytes(candidate.Data, option))
                    { chosen = number; oldOption = candidate; found = true; break; }
                }
            }
            if (!found) throw new InvalidOperationException("No unused firmware boot-option number is available.");
            string name = BootName(chosen);
            VariableState desiredOption = new VariableState(true, StandardAttributes, option);
            List<ushort> newOrder = new List<ushort>(); newOrder.Add(chosen);
            foreach (ushort number in order) if (number != chosen) newOrder.Add(number);
            VariableState desiredOrder = new VariableState(true, oldOrder.Exists ? oldOrder.Attributes : StandardAttributes, EncodeOrder(newOrder));
            VariableState desiredNext = new VariableState(true, oldNext.Exists ? oldNext.Attributes : StandardAttributes, BitConverter.GetBytes(chosen));
            if (!Directory.Exists(backupDirectory)) Directory.CreateDirectory(backupDirectory);
            if (Directory.GetFileSystemEntries(backupDirectory).Length != 0) throw new IOException("Firmware backup directory must be new and empty.");
            SaveState(backupDirectory, "before-BootOrder", oldOrder);
            SaveState(backupDirectory, "before-BootNext", oldNext);
            SaveState(backupDirectory, "before-" + name, oldOption);
            SaveState(backupDirectory, "planned-" + name, desiredOption);
            File.WriteAllText(Path.Combine(backupDirectory, "plan.txt"), "BootOption=" + name + "\r\nNewOption=" + (!oldOption.Exists).ToString() + "\r\n", Encoding.UTF8);
            Verify(variables, "BootOrder", oldOrder); Verify(variables, "BootNext", oldNext); Verify(variables, name, oldOption);
            bool optionTouched = false, orderTouched = false, nextTouched = false;
            try
            {
                if (!oldOption.Exists)
                { optionTouched = true; variables.Write(name, desiredOption); }
                Verify(variables, name, desiredOption);
                if (!EqualState(oldOrder, desiredOrder))
                { orderTouched = true; variables.Write("BootOrder", desiredOrder); }
                Verify(variables, "BootOrder", desiredOrder);
                if (!EqualState(oldNext, desiredNext))
                { nextTouched = true; variables.Write("BootNext", desiredNext); }
                Verify(variables, "BootNext", desiredNext);
                Verify(variables, name, desiredOption); Verify(variables, "BootOrder", desiredOrder); Verify(variables, "BootNext", desiredNext);
                SaveState(backupDirectory, "after-" + name, variables.Read(name));
                SaveState(backupDirectory, "after-BootOrder", variables.Read("BootOrder"));
                SaveState(backupDirectory, "after-BootNext", variables.Read("BootNext"));
                File.WriteAllText(Path.Combine(backupDirectory, "result.txt"), "Status=VERIFIED\r\nBootOption=" + name + "\r\n", Encoding.UTF8);
                return name;
            }
            catch (Exception failure)
            {
                List<string> problems = new List<string>();
                if (nextTouched) Restore(variables, "BootNext", oldNext, problems);
                if (orderTouched) Restore(variables, "BootOrder", oldOrder, problems);
                if (optionTouched)
                {
                    bool referenced = true;
                    try
                    {
                        VariableState checkOrder = variables.Read("BootOrder"), checkNext = variables.Read("BootNext");
                        ValidateOrder(checkOrder); ValidateNext(checkNext);
                        referenced = DecodeOrder(checkOrder).Contains(chosen) || (checkNext.Exists && Read16(checkNext.Data, 0) == chosen);
                    }
                    catch (Exception e) { problems.Add("Cannot check remaining references: " + e.Message); }
                    if (!referenced) Restore(variables, name, oldOption, problems);
                    else problems.Add("Retained " + name + " because firmware may still reference it.");
                }
                try
                {
                    Verify(variables, "BootOrder", oldOrder); Verify(variables, "BootNext", oldNext);
                    if (problems.Count == 0) Verify(variables, name, oldOption);
                }
                catch (Exception e) { problems.Add("Rollback readback: " + e.Message); }
                string result = "Firmware repair failed: " + failure.Message + " Rollback: " + (problems.Count == 0 ? "verified" : String.Join("; ", problems.ToArray()));
                try { File.WriteAllText(Path.Combine(backupDirectory, "result.txt"), "Status=FAILED\r\n" + result, Encoding.UTF8); } catch { }
                throw new InvalidOperationException(result, failure);
            }
        }

        private static void Restore(IVariables variables, string name, VariableState state, List<string> problems)
        {
            try { variables.Write(name, state); Verify(variables, name, state); }
            catch (Exception e) { problems.Add(name + ": " + e.Message); }
        }
        private static void SaveState(string directory, string name, VariableState state)
        {
            string file = Path.Combine(directory, name + ".bin");
            using (FileStream stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            { stream.Write(state.Data, 0, state.Data.Length); stream.Flush(true); }
            File.WriteAllText(Path.Combine(directory, name + ".state.txt"),
                "Exists=" + state.Exists.ToString() + "\r\nAttributes=0x" + state.Attributes.ToString("X8", CultureInfo.InvariantCulture) +
                "\r\nBytes=" + state.Data.Length.ToString(CultureInfo.InvariantCulture) + "\r\n", Encoding.ASCII);
        }
        internal static void Verify(IVariables variables, string name, VariableState state)
        { if (!EqualState(variables.Read(name), state)) throw new InvalidOperationException("Firmware readback mismatch: " + name); }
        internal static bool EqualState(VariableState left, VariableState right)
        { return left.Exists == right.Exists && left.Attributes == right.Attributes && EqualBytes(left.Data, right.Data); }
        internal static bool EqualBytes(byte[] left, byte[] right)
        { if (left.Length != right.Length) return false; for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false; return true; }
        internal static string BootName(ushort number) { return "Boot" + number.ToString("X4", CultureInfo.InvariantCulture); }
        internal static bool IsAllowedName(string name)
        {
            if (name == "BootOrder" || name == "BootNext") return true;
            if (name == null || name.Length != 8 || !name.StartsWith("Boot", StringComparison.Ordinal)) return false;
            for (int i = 4; i < 8; i++) if (!(name[i] >= '0' && name[i] <= '9') && !(name[i] >= 'A' && name[i] <= 'F')) return false;
            return true;
        }
        private static void ValidateOrder(VariableState state)
        { if (state.Exists && (state.Attributes != StandardAttributes || state.Data.Length == 0 || state.Data.Length % 2 != 0)) throw new InvalidOperationException("Unexpected BootOrder format or attributes."); }
        private static void ValidateNext(VariableState state)
        { if (state.Exists && (state.Attributes != StandardAttributes || state.Data.Length != 2)) throw new InvalidOperationException("Unexpected BootNext format or attributes."); }
        private static List<ushort> DecodeOrder(VariableState state)
        { List<ushort> list = new List<ushort>(); if (state.Exists) for (int i = 0; i < state.Data.Length; i += 2) list.Add(Read16(state.Data, i)); return list; }
        internal static byte[] EncodeOrder(List<ushort> list)
        { byte[] data = new byte[list.Count * 2]; for (int i = 0; i < list.Count; i++) { data[2 * i] = (byte)list[i]; data[2 * i + 1] = (byte)(list[i] >> 8); } return data; }
        internal static ushort Read16(byte[] data, int offset) { return (ushort)(data[offset] | data[offset + 1] << 8); }
        internal static uint Read32(byte[] data, int offset) { return BitConverter.ToUInt32(data, offset); }
        internal static ulong Read64(byte[] data, int offset) { return BitConverter.ToUInt64(data, offset); }
        private static Win32Exception Win32Failure(int error, string operation)
        { return new Win32Exception(error, operation + " failed (Win32 " + error.ToString(CultureInfo.InvariantCulture) + "): " + new Win32Exception(error).Message); }

        private static void GuardEnvironment()
        {
            Native.SYSTEM_INFO info; Native.GetNativeSystemInfo(out info);
            if (info.ProcessorArchitecture != 12 || IntPtr.Size != 8) throw new InvalidOperationException("Firmware changes require native ARM64 Windows PE.");
            uint type; if (!Native.GetFirmwareType(out type)) throw Win32Failure(Marshal.GetLastWin32Error(), "Detect firmware type");
            if (type != 2) throw new InvalidOperationException("UEFI firmware is required.");
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey("SYSTEM\\CurrentControlSet\\Control\\MiniNT"))
            { if (key == null) throw new InvalidOperationException("Firmware changes are permitted only inside Windows PE."); }
        }

        private sealed class NativeVariables : IVariables
        {
            private const string GlobalGuid = "{8BE4DF61-93CA-11d2-AA0D-00E098032B8C}";
            public VariableState Read(string name)
            {
                if (!IsAllowedName(name)) throw new ArgumentException("Variable name is outside boot-repair scope.");
                byte[] buffer = new byte[MaximumVariableBytes]; uint attributes;
                uint length = Native.GetFirmwareEnvironmentVariableExW(name, GlobalGuid, buffer, (uint)buffer.Length, out attributes);
                if (length == 0)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 203) return VariableState.Missing();
                    throw Win32Failure(error, "Read UEFI variable " + name);
                }
                if (length > buffer.Length) throw new InvalidOperationException("Firmware variable exceeds the size limit.");
                byte[] data = new byte[(int)length]; Array.Copy(buffer, data, data.Length);
                return new VariableState(true, attributes, data);
            }
            public void Write(string name, VariableState state)
            {
                if (!IsAllowedName(name)) throw new ArgumentException("Variable name is outside boot-repair scope.");
                if (state.Data.Length > MaximumVariableBytes || (state.Exists && (state.Attributes != StandardAttributes || state.Data.Length == 0)))
                    throw new ArgumentException("Unsupported firmware variable size or attributes.");
                if (!state.Exists && !Read(name).Exists) return;
                if (!Native.SetFirmwareEnvironmentVariableExW(name, GlobalGuid, state.Exists ? state.Data : null,
                    state.Exists ? (uint)state.Data.Length : 0, state.Exists ? state.Attributes : 0))
                    throw Win32Failure(Marshal.GetLastWin32Error(), "Write UEFI variable " + name);
            }
        }

        private sealed class PrivilegeScope : IDisposable
        {
            private IntPtr token; private Native.TOKEN_PRIVILEGES previous; private bool restore;
            internal PrivilegeScope()
            {
                if (!Native.OpenProcessToken(Native.GetCurrentProcess(), 0x28, out token)) throw Win32Failure(Marshal.GetLastWin32Error(), "Open process token");
                try
                {
                    Native.LUID id;
                    if (!Native.LookupPrivilegeValueW(null, "SeSystemEnvironmentPrivilege", out id)) throw Win32Failure(Marshal.GetLastWin32Error(), "Find firmware privilege");
                    Native.TOKEN_PRIVILEGES enable = new Native.TOKEN_PRIVILEGES(); enable.Count = 1; enable.Luid = id; enable.Attributes = 2;
                    uint returned; Native.SetLastError(0);
                    if (!Native.AdjustTokenPrivileges(token, false, ref enable, (uint)Marshal.SizeOf(typeof(Native.TOKEN_PRIVILEGES)), out previous, out returned))
                        throw Win32Failure(Marshal.GetLastWin32Error(), "Enable firmware privilege");
                    int error = Marshal.GetLastWin32Error();
                    if (error != 0) throw Win32Failure(error, "Grant firmware privilege");
                    restore = true;
                }
                catch { Native.CloseHandle(token); token = IntPtr.Zero; throw; }
            }
            public void Dispose()
            {
                if (token == IntPtr.Zero) return;
                if (restore) { Native.TOKEN_PRIVILEGES ignored; uint returned; Native.AdjustTokenPrivileges(token, false, ref previous, (uint)Marshal.SizeOf(typeof(Native.TOKEN_PRIVILEGES)), out ignored, out returned); }
                Native.CloseHandle(token); token = IntPtr.Zero;
            }
        }

        private static class Native
        {
            [StructLayout(LayoutKind.Sequential)] internal struct SYSTEM_INFO { internal ushort ProcessorArchitecture, Reserved; internal uint PageSize; internal IntPtr MinimumAddress, MaximumAddress; internal UIntPtr ProcessorMask; internal uint ProcessorCount, ProcessorType, AllocationGranularity; internal ushort ProcessorLevel, ProcessorRevision; }
            [StructLayout(LayoutKind.Sequential)] internal struct LUID { internal uint LowPart; internal int HighPart; }
            [StructLayout(LayoutKind.Sequential)] internal struct TOKEN_PRIVILEGES { internal uint Count; internal LUID Luid; internal uint Attributes; }
            [DllImport("kernel32.dll")] internal static extern void GetNativeSystemInfo(out SYSTEM_INFO info);
            [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetFirmwareType(out uint type);
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] internal static extern uint GetFirmwareEnvironmentVariableExW(string name, string guid, [Out] byte[] value, uint size, out uint attributes);
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetFirmwareEnvironmentVariableExW(string name, string guid, [In] byte[] value, uint size, uint attributes);
            [DllImport("kernel32.dll")] internal static extern IntPtr GetCurrentProcess();
            [DllImport("kernel32.dll")] internal static extern void SetLastError(uint error);
            [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseHandle(IntPtr handle);
            [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
            [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool LookupPrivilegeValueW(string system, string name, out LUID luid);
            [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AdjustTokenPrivileges(IntPtr token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TOKEN_PRIVILEGES state, uint length, out TOKEN_PRIVILEGES previous, out uint returned);
        }
    }

    internal interface IVariables { VariableState Read(string name); void Write(string name, VariableState state); }
    internal sealed class VariableState
    {
        internal readonly bool Exists; internal readonly uint Attributes; internal readonly byte[] Data;
        internal VariableState(bool exists, uint attributes, byte[] data) { Exists = exists; Attributes = attributes; Data = (byte[])data.Clone(); }
        internal static VariableState Missing() { return new VariableState(false, 0, new byte[0]); }
        internal VariableState Copy() { return new VariableState(Exists, Attributes, Data); }
    }
}
