import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// FileView-backed reader/writer for the shared watchlist + alert state at
// ~/.local/state/omarchy/stocks.json. Both Service.qml and Panel.qml keep
// their own instance on the same path; the file watch keeps them in sync
// (the same pattern the weather plugin uses for its location file).
Item {
  id: root

  property string dir: Quickshell.env("HOME") + "/.local/state/omarchy"
  property string path: dir + "/stocks.json"
  property var state: Model.defaultState()
  property bool ready: false

  signal changed()

  function reload() { file.reload() }

  // Replace the whole document. Callers usually go through mutate().
  function write(nextState) {
    var normalized = Model.normalizeState(nextState)
    root.state = normalized
    file.setText(JSON.stringify(normalized, null, 2) + "\n")
    root.changed()
  }

  // Apply fn to a deep clone of the current state, then persist it.
  function mutate(fn) {
    var draft = JSON.parse(JSON.stringify(root.state))
    fn(draft)
    write(draft)
  }

  Component.onCompleted: mkdirProc.running = true

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.dir]
    onExited: file.reload()
  }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.state = Model.parseState(text())
      root.ready = true
      root.changed()
    }
    onLoadFailed: {
      root.state = Model.defaultState()
      root.ready = true
      root.changed()
    }
  }
}
