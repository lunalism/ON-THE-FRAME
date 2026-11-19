"""Focused check of the actual draft parser and setter body with a command-boundary double.
Run with an approved build output directory argument. Does not launch the application.
The double uses the real engine Timeline/EditHistory; Preview integration is checked separately.
"""
from pathlib import Path
import subprocess
import sys
import uuid
import json

repo = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve(strict=True)
view = (repo / 'app/OnTheFrame/ContentView.swift').read_text()
store = (repo / 'app/OnTheFrame/ProjectStore.swift').read_text()
draft = 'struct SpectrumStyleDraft {' + view.split('struct SpectrumStyleDraft {', 1)[1].split('\nstruct SpectrumStyleAdjust:', 1)[0]
setter = '    func setSpectrumStyle' + store.split('    func setSpectrumStyle', 1)[1].split('    // MARK: 복사', 1)[0]
selection = '    private(set) var spectrumSelectionRevision' + store.split('    private(set) var spectrumSelectionRevision', 1)[1].split('    /// ⌘-클릭', 1)[0]
source = '''import Foundation
import OnTheFrameEngine
''' + draft + '''
final class CommandBoundary {
    var projectSession = 0, generation = 0
    var history: EditHistory
    var timeline: Timeline { history.timeline }
    var linkCandidate: UUID?
''' + selection + '''
    var gestureBase: Timeline?
    var fileCommandsAvailable = true, openRequested = false
    var openProgress: Int?, importProgress: Int?
    var imageImportBusy = false, relinkInProgress = false
    enum Phase { case idle, busy }
    var exportPhase = Phase.idle
    var discardConfirmed = false, editorClosedByUser = false
    var statusMessage: String?
    var commits = 0, invalidations = 0
    init(_ timeline: Timeline) { history = EditHistory(timeline) }
    func commit(_ make: (Timeline) throws -> Timeline, focus: UUID?) {
        do { history.apply(try make(timeline), focus: focus); commits += 1; generation += 1; invalidations += 1 }
        catch { statusMessage = String(describing: error) }
    }
''' + setter + '''
}
var count = 0
func check(_ condition: Bool, _ message: String) {
    count += 1
    if !condition { fatalError(message) }
}
let base: SpectrumItemStyle = SpectrumItemStyle.provisionalDefault
var draft = SpectrumStyleDraft(base)
check((try? draft.style(from: base)) == base, "exact draft round trip")
draft.startX = "-0.125"; draft.endX = "1600.001"; draft.height = "300.25"
draft.red = "12"; draft.green = "34"; draft.blue = "56"
let edited: SpectrumItemStyle = try draft.style(from: base)
check(edited.startXMilli == -125, "exact negative decimal")
check(edited.endXMilli == 1600001, "exact endpoint decimal")
check(edited.maxHeightMilli == 300250, "exact height decimal")
check(edited.alpha == base.alpha, "preserve alpha")
check(edited.thicknessMilli == base.thicknessMilli, "preserve thickness")
check(edited.mode == base.mode, "preserve mode")
check(edited.sides == base.sides, "preserve sides")
check(edited.analysisSettings == base.analysisSettings, "preserve analysis settings")
for text in ["nan", "inf", "1e3", "1.0001", "10000.001", "99999999999999999999999999999999999", ""] {
    var bad = draft; bad.startX = text
    check((try? bad.style(from: base)) == nil, "reject invalid coordinate " + text)
}
for text in ["-0.001", "1080.001"] {
    var bad = draft; bad.height = text
    check((try? bad.style(from: base)) == nil, "reject invalid height")
}
for text in ["256", "-1", "1.5", "NaN"] {
    var bad = draft; bad.red = text
    check((try? bad.style(from: base)) == nil, "reject invalid RGB")
}
var short = SpectrumStyleDraft(base); short.endX = short.startX; short.endY = short.startY
check((try? short.style(from: base)) == nil, "baseline at least one pixel")
let lane: UUID = UUID()
let laned: Timeline = try Timeline().addingLane(.spectrum, name: "SP", id: lane)
let timeline: Timeline = try laned.addingSpectrum(lane: lane, at: 0, length: 30, sourceKey: nil)
let id: UUID = timeline.spectra[0].id
func makeBoundary() -> CommandBoundary {
    let result = CommandBoundary(timeline)
    check(result.spectrumSelectionRevision == 0, "unselected initial revision")
    result.selection = id // Assign after initialization, as the actual selection path does.
    check(result.spectrumSelectionRevision == 1, "selection observer advances revision")
    return result
}
func request(_ boundary: CommandBoundary, _ style: SpectrumItemStyle = edited, project: Int = 0, revision: Int = 1, generation: Int = 0) -> String? {
    boundary.setSpectrumStyle(id, style: style, from: base, project: project, selectionRevision: revision, generation: generation)
}
let boundary = makeBoundary()
let noOpError: String? = request(boundary, base)
check(noOpError == nil, "no-op accepted")
check(boundary.commits == 0, "no-op does not commit")
check(!boundary.history.canUndo, "no-op has no history")
var cancelled = SpectrumStyleDraft(base); cancelled.red = "5"; cancelled = SpectrumStyleDraft(base)
check((try? cancelled.style(from: base)) == base, "Cancel resets only draft")
check(boundary.timeline == timeline, "Cancel leaves timeline untouched")
check(!boundary.history.canUndo, "Cancel leaves history untouched")
let applyError: String? = request(boundary)
check(applyError == nil, "Apply accepted")
check(boundary.commits == 1, "one Apply transaction")
check(boundary.invalidations == 1, "one command-boundary invalidation")
check(boundary.timeline.spectra[0].style == edited, "style applied")
boundary.history.undo()
check(boundary.timeline == timeline, "Undo restores timeline")
check(!boundary.history.canUndo, "only one Undo step")
boundary.history.redo(); check(boundary.timeline.spectra[0].style == edited, "exact Redo")
let stale = makeBoundary(); stale.selection = nil; stale.selection = id
let staleError: String? = request(stale)
check(staleError != nil, "selection away-and-back rejected")
check(stale.commits == 0, "selection away-and-back leaves history untouched")
let project = makeBoundary(); project.projectSession = 1
let projectError: String? = request(project)
check(projectError != nil, "project replacement rejected")
check(project.commits == 0, "project replacement leaves history untouched")
let generation = makeBoundary(); generation.generation = 1
let generationError: String? = request(generation)
check(generationError != nil, "history generation rejected")
check(generation.commits == 0, "history generation leaves history untouched")
let hidden = makeBoundary(); var changedAlpha = edited; changedAlpha.alpha = 0
let hiddenError: String? = request(hidden, changedAlpha)
check(hiddenError != nil, "hidden setting mutation rejected")
check(hidden.commits == 0, "hidden setting mutation leaves history untouched")
let busy = makeBoundary(); busy.fileCommandsAvailable = false
let busyError: String? = request(busy)
check(busyError != nil, "modal guard rejected")
check(busy.commits == 0, "modal guard leaves history untouched")
let invalid = makeBoundary(); var badStyle = edited; badStyle.red = 256
let invalidError: String? = request(invalid, badStyle)
check(invalidError != nil, "invalid command rejected")
check(invalid.commits == 0, "invalid command leaves history untouched")
print("PASS \\(count) focused draft/command-boundary assertions")
'''
# Guard the exact product extraction boundaries before any compilation.
assert draft.startswith('struct SpectrumStyleDraft {') and draft.rstrip().endswith('}')
assert setter.count('func setSpectrumStyle(') == 1 and 'try $0.settingSpectrumStyle(id, style)' in setter
assert 'selection != oldValue' in selection and 'spectrumSelectionRevision &+= 1' in selection
run_id = uuid.uuid4().hex
source_path = output / ('SpectrumStyleCommandCheck-' + run_id + '.swift')
binary_path = output / ('SpectrumStyleCommandCheck-' + run_id)
with source_path.open('x') as file:
    file.write(source)
products = output / 'Build/Products/Debug'
compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
syntax = [compiler, '-frontend', '-parse', str(source_path)]
sdk = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk'
assert Path(sdk).is_dir(), 'Xcode 27.2 SDK unavailable'
command = [compiler, '-sdk', sdk, '-j1', '-disable-batch-mode', '-I', str(products), str(source_path),
           str(products / 'OnTheFrameEngine.o'), '-o', str(binary_path)]
manifest = {'source': str(source_path), 'binary': str(binary_path), 'syntax': syntax, 'compile': command}
with (output / ('SpectrumStyleCommandCheck-' + run_id + '.json')).open('x') as file:
    json.dump(manifest, file)
print(json.dumps(manifest), flush=True)
syntax_result = subprocess.run(syntax)
print('SYNTAX_EXIT', syntax_result.returncode, flush=True)
if syntax_result.returncode:
    sys.exit(syntax_result.returncode)
compiled = subprocess.run(command)
print('COMPILER_EXIT', compiled.returncode, flush=True)
if compiled.returncode:
    sys.exit(compiled.returncode)
result = subprocess.run([str(binary_path)])
print('ASSERTIONS_EXIT', result.returncode, flush=True)
sys.exit(result.returncode)
