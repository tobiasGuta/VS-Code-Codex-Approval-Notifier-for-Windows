using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;

internal static class TestCodexFileChangeApprovalLogic
{
    private static int Failures;
    private static readonly Type Companion = typeof(CodexLocalCompanion);
    private const BindingFlags StaticPrivate = BindingFlags.Static | BindingFlags.NonPublic;

    private static void Pass(string name) { Console.WriteLine("  PASS  " + name); }
    private static void Fail(string name, string detail) { Console.Error.WriteLine("  FAIL  " + name + ": " + detail); Failures++; }
    private static void Assert(bool condition, string name) { if (condition) Pass(name); else Fail(name, "condition was false"); }

    private static MethodInfo Method(string name)
    {
        MethodInfo method = Companion.GetMethod(name, StaticPrivate);
        if (method == null) throw new InvalidOperationException("Missing method: " + name);
        return method;
    }

    private static FieldInfo Field(string name)
    {
        FieldInfo field = Companion.GetField(name, StaticPrivate);
        if (field == null) throw new InvalidOperationException("Missing field: " + name);
        return field;
    }

    private static object Normalize(object[] changes)
    {
        return Method("NormalizeFileEvidence").Invoke(null, new object[] { changes });
    }

    private static object EvidenceField(object evidence, string name)
    {
        FieldInfo field = evidence.GetType().GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        if (field == null) throw new InvalidOperationException("Missing evidence field: " + name);
        return field.GetValue(evidence);
    }

    private static bool Allowable(object evidence) { return Convert.ToBoolean(EvidenceField(evidence, "AllowOnceAvailable")); }
    private static string EvidenceStatus(object evidence) { return Convert.ToString(EvidenceField(evidence, "EvidenceStatus")); }
    private static string Signature(object evidence) { return Convert.ToString(EvidenceField(evidence, "Signature")); }

    private static Dictionary<string, object> Kind(string type, string movePath)
    {
        var kind = new Dictionary<string, object>();
        kind["type"] = type;
        if (movePath != null) kind["move_path"] = movePath;
        return kind;
    }

    private static Dictionary<string, object> Change(string path, string type, string diff, string movePath)
    {
        return new Dictionary<string, object>
        {
            { "path", path },
            { "kind", Kind(type, movePath) },
            { "diff", diff }
        };
    }

    private static Dictionary<string, object> Envelope(string method, object id, Dictionary<string, object> parameters)
    {
        var message = new Dictionary<string, object> { { "method", method }, { "params", parameters } };
        if (id != null) message["id"] = id;
        return message;
    }

    private static void ClearObjectWithClear(string fieldName)
    {
        object value = Field(fieldName).GetValue(null);
        value.GetType().GetMethod("Clear").Invoke(value, null);
    }

    private static void ResetState()
    {
        ClearObjectWithClear("PendingByHandle");
        ClearObjectWithClear("ActiveByRequestId");
        ClearObjectWithClear("CompletedRequestIds");
        ClearObjectWithClear("FileEvidenceByItem");
        ClearObjectWithClear("TerminalFileItems");
        ClearObjectWithClear("QuarantinedFileMessages");
        Field("ThreadId").SetValue(null, "thread-1");
        Field("Resuming").SetValue(null, false);
        Field("ApprovalTtlSeconds").SetValue(null, 300);
    }

    private static object[] Snapshot()
    {
        return (object[])Method("SnapshotPending").Invoke(null, null);
    }

    private static IDictionary FirstSnapshot()
    {
        object[] items = Snapshot();
        if (items.Length != 1) throw new InvalidOperationException("Expected exactly one pending approval, found " + items.Length + ".");
        return (IDictionary)items[0];
    }

    private static void StartFile(string diff)
    {
        var item = new Dictionary<string, object>
        {
            { "type", "fileChange" },
            { "id", "item-1" },
            { "status", "inProgress" },
            { "changes", new object[] { Change("src/a.cs", "update", diff, null) } }
        };
        var p = new Dictionary<string, object> { { "threadId", "thread-1" }, { "turnId", "turn-1" }, { "item", item } };
        Method("HandleAppServerMessageCore").Invoke(null, new object[] { Envelope("item/started", null, p) });
    }

    private static void RequestFile(object requestId)
    {
        var p = new Dictionary<string, object>
        {
            { "threadId", "thread-1" }, { "turnId", "turn-1" }, { "itemId", "item-1" }, { "reason", "test" }
        };
        Method("HandleAppServerMessageCore").Invoke(null, new object[] { Envelope("item/fileChange/requestApproval", requestId, p) });
    }

    private static void Patch(string diff)
    {
        var p = new Dictionary<string, object>
        {
            { "threadId", "thread-1" }, { "turnId", "turn-1" }, { "itemId", "item-1" },
            { "changes", new object[] { Change("src/a.cs", "update", diff, null) } }
        };
        Method("HandleAppServerMessageCore").Invoke(null, new object[] { Envelope("item/fileChange/patchUpdated", null, p) });
    }

    private static void ResolveNative(object requestId)
    {
        var p = new Dictionary<string, object> { { "threadId", "thread-1" }, { "requestId", requestId } };
        Method("HandleAppServerMessageCore").Invoke(null, new object[] { Envelope("serverRequest/resolved", null, p) });
    }

    private static void CompleteFile()
    {
        var item = new Dictionary<string, object>
        {
            { "type", "fileChange" }, { "id", "item-1" }, { "status", "completed" },
            { "changes", new object[] { Change("src/a.cs", "update", "@@ final", null) } }
        };
        var p = new Dictionary<string, object> { { "threadId", "thread-1" }, { "turnId", "turn-1" }, { "item", item } };
        Method("HandleAppServerMessageCore").Invoke(null, new object[] { Envelope("item/completed", null, p) });
    }

    private static void EvidenceTests()
    {
        Console.WriteLine("# Evidence validation");
        Assert(Allowable(Normalize(new object[] { Change("a.txt", "add", "+hello", null) })), "add with native content is allowable");
        Assert(Allowable(Normalize(new object[] { Change("a.txt", "delete", "-hello", null) })), "delete with native content is allowable");
        Assert(Allowable(Normalize(new object[] { Change("a.txt", "update", "@@ -1 +1", null) })), "update with diff is allowable");
        Assert(Allowable(Normalize(new object[] { Change("old.txt", "update", "", "new.txt") })), "move-only update is allowable");
        Assert(!Allowable(Normalize(new object[] { Change("a.txt", "update", "", null) })), "empty update is deny-only");
        Assert(!Allowable(Normalize(new object[] { Change("a.txt", "add", "", null) })), "empty add is deny-only");
        Assert(!Allowable(Normalize(new object[] { Change("a.txt", "mystery", "x", null) })), "unknown kind is deny-only");
        Assert(!Allowable(Normalize(new object[0])), "empty evidence is deny-only");

        var many = new object[101];
        for (int i = 0; i < many.Length; i++) many[i] = Change("f" + i + ".txt", "add", "+x", null);
        object tooMany = Normalize(many);
        Assert(!Allowable(tooMany) && EvidenceStatus(tooMany) == "incomplete", "more than 100 changes is incomplete/deny-only");

        object oversized = Normalize(new object[] { Change("large.txt", "add", "+" + new string('x', 270000), null) });
        Assert(!Allowable(oversized) && EvidenceStatus(oversized) == "incomplete", "oversized evidence is incomplete/deny-only");

        object sameA = Normalize(new object[] { Change("a.txt", "update", "@@ A", null) });
        object sameB = Normalize(new object[] { Change("a.txt", "update", "@@ A", null) });
        object changed = Normalize(new object[] { Change("a.txt", "update", "@@ B", null) });
        Assert(Signature(sameA) == Signature(sameB), "identical evidence has identical signature");
        Assert(Signature(sameA) != Signature(changed), "material evidence change changes signature");
    }

    private static void LifecycleTests()
    {
        Console.WriteLine();
        Console.WriteLine("# Item/request lifecycle");
        ResetState();
        StartFile("@@ A");
        Assert(Snapshot().Length == 0, "item/started alone publishes no handle");
        RequestFile(701);
        IDictionary first = FirstSnapshot();
        string firstHandle = Convert.ToString(first["handle"]);
        Assert(Convert.ToString(first["kind"]) == "fileChange", "request publishes typed fileChange approval");
        Assert(Convert.ToBoolean(first["allowOnceAvailable"]), "correlated native evidence enables Allow once");

        Patch("@@ B");
        IDictionary second = FirstSnapshot();
        string secondHandle = Convert.ToString(second["handle"]);
        Assert(firstHandle != secondHandle, "material patch update rotates pending handle");
        object[] secondChanges = (object[])second["changes"];
        IDictionary secondChange = (IDictionary)secondChanges[0];
        Assert(Convert.ToString(secondChange["diff"]) == "@@ B", "rotated handle exposes latest native evidence");

        ResolveNative(701);
        Assert(Snapshot().Length == 0, "serverRequest/resolved removes pending approval");
        Patch("@@ C");
        Assert(Snapshot().Length == 0, "resolved approval is not resurrected by patch update");

        ResetState();
        StartFile("@@ A");
        RequestFile(702);
        CompleteFile();
        Assert(Snapshot().Length == 0, "terminal item/completed removes pending approval");
        Patch("@@ B");
        Assert(Snapshot().Length == 0, "terminal item ignores later patch publication");
    }

    private static void BootstrapQuarantineTests()
    {
        Console.WriteLine();
        Console.WriteLine("# Bootstrap quarantine");
        ResetState();
        Field("Resuming").SetValue(null, true);
        var p = new Dictionary<string, object>
        {
            { "threadId", "thread-1" }, { "turnId", "turn-1" }, { "itemId", "item-1" }, { "reason", "queued" }
        };
        Method("HandleAppServerMessage").Invoke(null, new object[] { Envelope("item/fileChange/requestApproval", 703, p) });
        Assert(Snapshot().Length == 0, "file approval is not published while Resuming");
        object quarantine = Field("QuarantinedFileMessages").GetValue(null);
        int count = Convert.ToInt32(quarantine.GetType().GetProperty("Count").GetValue(quarantine, null));
        Assert(count == 1, "file approval is quarantined during resume");

        ResolveNative(703);
        Field("Resuming").SetValue(null, false);
        IList queued = (IList)quarantine;
        Method("HandleAppServerMessageCore").Invoke(null, new object[] { queued[0] });
        Assert(Snapshot().Length == 0, "resolved request tombstone suppresses quarantined replay");
    }

    internal static int Main(string[] args)
    {
        try
        {
            EvidenceTests();
            LifecycleTests();
            BootstrapQuarantineTests();
        }
        catch (Exception ex)
        {
            Fail("unexpected exception", ex.ToString());
        }

        Console.WriteLine();
        if (Failures == 0)
        {
            Console.WriteLine("PASS  Deterministic file-change approval logic tests passed.");
            return 0;
        }
        Console.Error.WriteLine("FAIL  " + Failures + " test(s) failed.");
        return 1;
    }
}
