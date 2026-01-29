import Testing
@testable import SwiftDiffs

@Suite("Myers Diff Algorithm")
struct MyersDiffTests {

    @Test("Empty sequences")
    func emptySequences() {
        let result = MyersDiff.diff(old: [Int](), new: [Int]())
        #expect(result.isEmpty)
    }

    @Test("Empty old sequence")
    func emptyOldSequence() {
        let result = MyersDiff.diff(old: [Int](), new: [1, 2, 3])
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.isInsert })
    }

    @Test("Empty new sequence")
    func emptyNewSequence() {
        let result = MyersDiff.diff(old: [1, 2, 3], new: [Int]())
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.isDelete })
    }

    @Test("Identical sequences")
    func identicalSequences() {
        let result = MyersDiff.diff(old: [1, 2, 3], new: [1, 2, 3])
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.isEqual })
    }

    @Test("Single insertion")
    func singleInsertion() {
        let result = MyersDiff.diff(old: [1, 3], new: [1, 2, 3])
        #expect(result.count == 3)

        let inserts = result.filter { $0.isInsert }
        #expect(inserts.count == 1)
        #expect(inserts.first?.value == 2)
    }

    @Test("Single deletion")
    func singleDeletion() {
        let result = MyersDiff.diff(old: [1, 2, 3], new: [1, 3])
        #expect(result.count == 3)

        let deletes = result.filter { $0.isDelete }
        #expect(deletes.count == 1)
        #expect(deletes.first?.value == 2)
    }

    @Test("Line diffing")
    func lineDiffing() {
        let old = """
        line1
        line2
        line3
        """
        let new = """
        line1
        modified
        line3
        """

        let result = MyersDiff.diffLines(old: old, new: new)
        #expect(result.count == 4) // equal, delete, insert, equal

        let deletes = result.filter { $0.isDelete }
        let inserts = result.filter { $0.isInsert }

        #expect(deletes.count == 1)
        #expect(inserts.count == 1)
        #expect(deletes.first?.value == "line2")
        #expect(inserts.first?.value == "modified")
    }

    @Test("Word diffing")
    func wordDiffing() {
        let old = "hello world"
        let new = "hello swift"

        let result = MyersDiff.diffWords(old: old, new: new)

        let deletes = result.filter { $0.isDelete }
        let inserts = result.filter { $0.isInsert }

        #expect(deletes.count == 1)
        #expect(inserts.count == 1)
        #expect(deletes.first?.value == "world")
        #expect(inserts.first?.value == "swift")
    }

    @Test("DiffLine conversion")
    func diffLineConversion() {
        let old = "a\nb\nc"
        let new = "a\nx\nc"

        let edits = MyersDiff.diffLines(old: old, new: new)
        let lines = MyersDiff.toDiffLines(edits: edits)

        #expect(lines.count == 4)
        #expect(lines[0].type == .context)
        #expect(lines[1].type == .deletion)
        #expect(lines[2].type == .addition)
        #expect(lines[3].type == .context)
    }

    @Test("Hunk creation")
    func hunkCreation() {
        let old = "a\nb\nc\nd\ne\nf\ng"
        let new = "a\nb\nx\nd\ne\nf\ng"

        let edits = MyersDiff.diffLines(old: old, new: new)
        let lines = MyersDiff.toDiffLines(edits: edits)
        let hunks = MyersDiff.toHunks(lines: lines, contextLines: 2)

        #expect(hunks.count == 1)
        #expect(hunks[0].lines.count == 6) // 2 context + 1 del + 1 add + 2 context
    }
}

@Suite("Patch Parser")
struct PatchParserTests {

    @Test("Parse git diff header")
    func parseGitDiffHeader() {
        let diff = """
        diff --git a/src/file.swift b/src/file.swift
        index abc123..def456 100644
        --- a/src/file.swift
        +++ b/src/file.swift
        @@ -1,3 +1,3 @@
         line1
        -old line
        +new line
         line3
        """

        let patch = PatchParser.parse(diff)
        #expect(patch.files.count == 1)
        #expect(patch.files[0].displayPath == "src/file.swift")
        #expect(patch.files[0].hunks.count == 1)
    }

    @Test("Parse multiple files")
    func parseMultipleFiles() {
        let diff = """
        diff --git a/file1.swift b/file1.swift
        --- a/file1.swift
        +++ b/file1.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/file2.swift b/file2.swift
        --- a/file2.swift
        +++ b/file2.swift
        @@ -1 +1 @@
        -foo
        +bar
        """

        let patch = PatchParser.parse(diff)
        #expect(patch.files.count == 2)
        #expect(patch.files[0].displayPath == "file1.swift")
        #expect(patch.files[1].displayPath == "file2.swift")
    }

    @Test("Parse new file")
    func parseNewFile() {
        let diff = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """

        let patch = PatchParser.parse(diff)
        #expect(patch.files.count == 1)
        #expect(patch.files[0].changeType == .added)
    }

    @Test("Parse hunk header with function context")
    func parseHunkHeaderWithFunction() {
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -10,5 +10,6 @@ func myFunction() {
         context
        +addition
        """

        let patch = PatchParser.parse(diff)
        #expect(patch.files[0].hunks[0].header == "func myFunction() {")
    }
}

@Suite("Diff Engine")
struct DiffEngineTests {

    @Test("Sync diff computation")
    func syncDiffComputation() async {
        let engine = DiffEngine()
        let old = "line1\nline2\nline3"
        let new = "line1\nmodified\nline3"

        let diff = engine.diffSync(old: old, new: new)
        #expect(diff.hunks.count == 1)
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)
    }

    @Test("Async diff computation")
    func asyncDiffComputation() async {
        let engine = DiffEngine()
        let old = "hello world"
        let new = "hello swift"

        let diff = await engine.diff(old: old, new: new)
        #expect(diff.hunks.count == 1)
    }

    @Test("Split row conversion")
    func splitRowConversion() async {
        let engine = DiffEngine()
        let old = "a\nb\nc"
        let new = "a\nx\nc"

        let diff = await engine.diff(old: old, new: new)
        let rows = await engine.toSplitRows(hunk: diff.hunks[0])

        // Should have: context, del+add pair, context
        #expect(rows.count == 3)
        #expect(rows[0].leftLine != nil && rows[0].rightLine != nil) // context
        #expect(rows[1].leftLine?.type == .deletion)
        #expect(rows[1].rightLine?.type == .addition)
    }

    @Test("Inline highlighting")
    func inlineHighlighting() async {
        let engine = DiffEngine()
        let old = "hello world"
        let new = "hello swift"

        let (diff, inlines) = await engine.diffWithInlineHighlighting(old: old, new: new)

        #expect(diff.hunks.count == 1)
        #expect(!inlines.isEmpty)
    }
}
