// Pure/mock tests only. Does not instantiate the native firmware backend or call Repair/Probe.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using ArmBootRepair;

internal static class FirmwareBootTests
{
    private static int checks;
    private static string root;
    private static readonly Guid Esp = new Guid("00112233-4455-6677-8899-aabbccddeeff");
    private static readonly byte[] Option = FirmwareBoot.BuildLoadOption(Esp, 1, 1048576, 536870912, 512);
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); checks++; }
    private static string NewDirectory() { return Path.Combine(root, Guid.NewGuid().ToString("N")); }
    private static VariableState State(byte[] value) { return new VariableState(true, 7, value); }
    private static byte[] Order(params ushort[] ids) { return FirmwareBoot.EncodeOrder(new List<ushort>(ids)); }
    private static string Fails(Action action)
    { try { action(); } catch (Exception e) { checks++; return e.Message; } throw new Exception("Expected failure was not raised."); }

    public static int Main(string[] args)
    {
        try
        {
            root = args.Length == 1 ? args[0] : Path.Combine(Path.GetTempPath(), "ArmBootRepair-MockTests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            Check(FirmwareBoot.SelfTest().StartsWith("PASS"), "Public pure codec self-test");
            CodecTests();
            SuccessTests();
            FaultTests();
            Console.WriteLine("PASS: " + checks + " codec/transaction checks. In-memory firmware backend only; no native firmware APIs called.");
            Console.WriteLine("Test fixture files: " + root);
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e.ToString()); return 1; }
    }

    private static void CodecTests()
    {
        int descriptionLength = Encoding.Unicode.GetByteCount(FirmwareBoot.Description + "\0");
        int start = 6 + descriptionLength;
        Check(FirmwareBoot.Read32(Option, 0) == 1, "ACTIVE load-option attribute");
        Check(FirmwareBoot.Read16(Option, 4) == Option.Length - start, "FilePathListLength includes all nodes and end");
        Check(Encoding.Unicode.GetString(Option, 6, descriptionLength) == FirmwareBoot.Description + "\0", "UTF16 description terminator");
        Check(Option[start] == 4 && Option[start + 1] == 1 && FirmwareBoot.Read16(Option, start + 2) == 42, "HD node header");
        Check(FirmwareBoot.Read32(Option, start + 4) == 1, "GPT partition number");
        Check(FirmwareBoot.Read64(Option, start + 8) == 2048, "Starting LBA");
        Check(FirmwareBoot.Read64(Option, start + 16) == 1048576, "Partition size in LBAs");
        byte[] guidBytes = new byte[16]; Array.Copy(Option, start + 24, guidBytes, 0, 16);
        Check(new Guid(guidBytes) == Esp, "GPT GUID encoding roundtrip");
        Check(guidBytes[0] == 0x33 && guidBytes[1] == 0x22 && guidBytes[2] == 0x11 && guidBytes[3] == 0x00, "GPT mixed-endian GUID encoding");
        Check(Option[start + 40] == 2 && Option[start + 41] == 2, "GPT format and GUID signature type");
        int fileNode = start + 42;
        int fileLength = FirmwareBoot.Read16(Option, fileNode + 2);
        Check(Option[fileNode] == 4 && Option[fileNode + 1] == 4, "FilePath node type");
        Check(Encoding.Unicode.GetString(Option, fileNode + 4, fileLength - 4) == FirmwareBoot.ManagerPath + "\0", "Exact EFI loader path");
        int end = fileNode + fileLength;
        Check(end + 4 == Option.Length && Option[end] == 0x7f && Option[end + 1] == 0xff && FirmwareBoot.Read16(Option, end + 2) == 4, "End node and no optional data");
        byte[] fourK = FirmwareBoot.BuildLoadOption(Esp, 1, 1048576, 536870912, 4096);
        Check(FirmwareBoot.Read64(fourK, start + 8) == 256 && FirmwareBoot.Read64(fourK, start + 16) == 131072, "4K logical sectors");
        Fails(delegate { FirmwareBoot.BuildLoadOption(Guid.Empty, 1, 1048576, 536870912, 512); });
        Fails(delegate { FirmwareBoot.BuildLoadOption(Esp, 0, 1048576, 536870912, 512); });
        Fails(delegate { FirmwareBoot.BuildLoadOption(Esp, 1, 1048577, 536870912, 512); });
        Fails(delegate { FirmwareBoot.BuildLoadOption(Esp, 1, 1048576, 536870912, 1024); });
        Check(!FirmwareBoot.IsAllowedName("PK") && !FirmwareBoot.IsAllowedName("dbx") && !FirmwareBoot.IsAllowedName("BootCurrent"), "Secure Boot and unrelated variables denied");
        Check(FirmwareBoot.IsAllowedName("Boot1000") && FirmwareBoot.IsAllowedName("BootOrder") && FirmwareBoot.IsAllowedName("BootNext"), "Only scoped boot variables allowed");
    }

    private static void SuccessTests()
    {
        MockVariables fresh = Seed();
        string directory = NewDirectory();
        string selected = FirmwareBoot.RepairCore(fresh, Option, directory);
        Check(selected == "Boot1000", "Allocate first unused option");
        Check(FirmwareBoot.EqualBytes(fresh.Read("BootOrder").Data, Order(0x1000, 2, 4)), "Preserve original boot entries in order");
        Check(FirmwareBoot.Read16(fresh.Read("BootNext").Data, 0) == 0x1000, "Set next boot");
        Check(FirmwareBoot.EqualBytes(fresh.Read(selected).Data, Option), "Option exact readback");
        Check(fresh.WriteCount == 3, "Exactly option/order/next writes");
        Check(File.Exists(Path.Combine(directory, "before-BootOrder.bin")) && File.Exists(Path.Combine(directory, "before-BootNext.state.txt")), "Before-state backups persist");
        Check(File.ReadAllText(Path.Combine(directory, "result.txt")).Contains("Status=VERIFIED"), "Verified result recorded");

        fresh.WriteCount = 0;
        Check(FirmwareBoot.RepairCore(fresh, Option, NewDirectory()) == selected, "Idempotent reuse");
        Check(fresh.WriteCount == 0, "Already correct boot variables need no writes");

        MockVariables reused = Seed(); reused.Values["Boot1000"] = State(Option); reused.Values["BootOrder"] = State(Order(2, 0x1000, 4, 0x1000));
        Check(FirmwareBoot.RepairCore(reused, Option, NewDirectory()) == "Boot1000", "Reuse owned option in order");
        Check(FirmwareBoot.EqualBytes(reused.Read("BootOrder").Data, Order(0x1000, 2, 4)), "Remove only chosen option duplicates");
        Check(!reused.Writes.Contains("Boot1000"), "Reused option bytes never overwritten");

        MockVariables orphan = Seed(); orphan.Values["Boot1000"] = State(new byte[] { 99, 88, 77 });
        Check(FirmwareBoot.RepairCore(orphan, Option, NewDirectory()) == "Boot1001", "Do not overwrite an unlisted existing Boot####");
        Check(FirmwareBoot.EqualBytes(orphan.Read("Boot1000").Data, new byte[] { 99, 88, 77 }), "Foreign option preserved");

        MockVariables missing = new MockVariables();
        Check(FirmwareBoot.RepairCore(missing, Option, NewDirectory()) == "Boot1000", "Create order and next when absent");
        Check(FirmwareBoot.EqualBytes(missing.Read("BootOrder").Data, Order(0x1000)), "New order contains exactly repair entry");
    }

    private static void FaultTests()
    {
        for (int fail = 1; fail <= 3; fail++)
        {
            foreach (bool mutate in new bool[] { false, true })
            {
                MockVariables vars = Seed(); Dictionary<string, VariableState> snapshot = vars.Snapshot();
                vars.FailWrites.Add(fail); vars.MutateBeforeFailure = mutate;
                string message = Fails(delegate { FirmwareBoot.RepairCore(vars, Option, NewDirectory()); });
                Check(message.Contains("Rollback: verified"), "Write failure rollback reported verified " + fail);
                Check(vars.EqualsSnapshot(snapshot), "Write failure restores exact state, including attributes/existence " + fail + "/" + mutate);
            }
        }
        string[] names = new string[] { "Boot1000", "BootOrder", "BootNext" };
        for (int i = 0; i < names.Length; i++)
        {
            MockVariables vars = Seed(); Dictionary<string, VariableState> snapshot = vars.Snapshot();
            vars.CorruptName = names[i]; vars.CorruptAfterWrites = i + 1;
            string message = Fails(delegate { FirmwareBoot.RepairCore(vars, Option, NewDirectory()); });
            Check(message.Contains("Rollback: verified"), "Readback corruption is detected and rolled back " + names[i]);
            Check(vars.EqualsSnapshot(snapshot), "Readback-corruption exact rollback " + names[i]);
        }
        MockVariables absent = new MockVariables(); absent.FailWrites.Add(3); absent.MutateBeforeFailure = true;
        Fails(delegate { FirmwareBoot.RepairCore(absent, Option, NewDirectory()); });
        Check(absent.Values.Count == 0, "Absent BootOrder/BootNext/option restored by deletion");

        MockVariables malformed = Seed(); malformed.Values["BootOrder"] = State(new byte[] { 1 });
        Fails(delegate { FirmwareBoot.RepairCore(malformed, Option, NewDirectory()); });
        Check(malformed.WriteCount == 0, "Malformed order fails before firmware write");
        MockVariables badAttributes = Seed(); badAttributes.Values["BootNext"] = new VariableState(true, 3, Order(4));
        Fails(delegate { FirmwareBoot.RepairCore(badAttributes, Option, NewDirectory()); });
        Check(badAttributes.WriteCount == 0, "Unsupported attributes fail before firmware write");

        MockVariables failedRollback = Seed(); failedRollback.FailWrites.Add(3); failedRollback.FailWrites.Add(5);
        string failedMessage = Fails(delegate { FirmwareBoot.RepairCore(failedRollback, Option, NewDirectory()); });
        Check(failedMessage.Contains("Retained Boot1000") && !failedMessage.Contains("Rollback: verified"), "Rollback failure explicitly reported");
        Check(failedRollback.Read("Boot1000").Exists, "Do not delete new option still referenced after rollback failure");

        MockVariables duplicateBackup = Seed(); string used = NewDirectory(); Directory.CreateDirectory(used); File.WriteAllText(Path.Combine(used, "existing.txt"), "keep");
        Fails(delegate { FirmwareBoot.RepairCore(duplicateBackup, Option, used); });
        Check(duplicateBackup.WriteCount == 0 && File.ReadAllText(Path.Combine(used, "existing.txt")) == "keep", "Existing backup never overwritten");

        MockVariables race = Seed(); race.ChangeOrderBeforeCommit = true;
        Fails(delegate { FirmwareBoot.RepairCore(race, Option, NewDirectory()); });
        Check(race.WriteCount == 0 && FirmwareBoot.EqualBytes(race.Read("BootOrder").Data, Order(9)), "Concurrent change detected before own writes");
    }

    private static MockVariables Seed()
    {
        MockVariables vars = new MockVariables();
        vars.Values["BootOrder"] = State(Order(2, 4)); vars.Values["BootNext"] = State(Order(4));
        vars.Values["Boot0002"] = State(new byte[] { 1, 2, 3 }); vars.Values["Boot0004"] = State(new byte[] { 4, 5, 6 });
        return vars;
    }

    private sealed class MockVariables : IVariables
    {
        internal Dictionary<string, VariableState> Values = new Dictionary<string, VariableState>();
        internal HashSet<int> FailWrites = new HashSet<int>();
        internal List<string> Writes = new List<string>();
        internal int WriteCount; internal bool MutateBeforeFailure;
        internal string CorruptName; internal int CorruptAfterWrites; private bool corrupted;
        internal bool ChangeOrderBeforeCommit; private int orderReads;
        public VariableState Read(string name)
        {
            if (!FirmwareBoot.IsAllowedName(name)) throw new Exception("Out-of-scope variable read");
            if (name == "BootOrder")
            {
                orderReads++;
                if (ChangeOrderBeforeCommit && orderReads == 2) Values[name] = State(Order(9));
            }
            VariableState value; VariableState result = Values.TryGetValue(name, out value) ? value.Copy() : VariableState.Missing();
            if (!corrupted && name == CorruptName && WriteCount >= CorruptAfterWrites)
            {
                corrupted = true;
                byte[] changed = result.Data.Length == 0 ? new byte[] { 1 } : (byte[])result.Data.Clone(); changed[0] ^= 0x40;
                return new VariableState(true, result.Attributes, changed);
            }
            return result;
        }
        public void Write(string name, VariableState state)
        {
            if (!FirmwareBoot.IsAllowedName(name)) throw new Exception("Out-of-scope variable write");
            WriteCount++; Writes.Add(name);
            if (FailWrites.Contains(WriteCount))
            {
                if (MutateBeforeFailure) Put(name, state);
                throw new IOException("Injected write failure " + WriteCount);
            }
            Put(name, state);
        }
        private void Put(string name, VariableState state) { if (state.Exists) Values[name] = state.Copy(); else Values.Remove(name); }
        internal Dictionary<string, VariableState> Snapshot()
        { Dictionary<string, VariableState> result = new Dictionary<string, VariableState>(); foreach (KeyValuePair<string, VariableState> item in Values) result[item.Key] = item.Value.Copy(); return result; }
        internal bool EqualsSnapshot(Dictionary<string, VariableState> snapshot)
        {
            if (snapshot.Count != Values.Count) return false;
            foreach (KeyValuePair<string, VariableState> item in snapshot)
            { VariableState found; if (!Values.TryGetValue(item.Key, out found) || !FirmwareBoot.EqualState(item.Value, found)) return false; }
            return true;
        }
    }
}
