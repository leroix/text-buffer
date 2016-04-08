Patch = require 'atom-patch'
MarkerLayer = require './marker-layer'

SerializationVersion = 5

class Checkpoint
  constructor: (@id, @snapshot, @isBoundary) ->
    unless @snapshot?
      global.atom?.assert(false, "Checkpoint created without snapshot")
      @snapshot = {}

class Transaction
  constructor: (@markerSnapshotBefore, @patch, @markerSnapshotAfter, @groupingInterval=0) ->
    @timestamp = Date.now()

  shouldGroupWith: (previousTransaction) ->
    timeBetweenTransactions = @timestamp - previousTransaction.timestamp
    timeBetweenTransactions < Math.min(@groupingInterval, previousTransaction.groupingInterval)

  groupWith: (previousTransaction) ->
    new Transaction(
      previousTransaction.markerSnapshotBefore,
      Patch.compose([previousTransaction.patch, @patch]),
      @markerSnapshotAfter,
      @groupingInterval
    )

# Manages undo/redo for {TextBuffer}
module.exports =
class History
  @deserialize: (state, buffer) ->
    history = new History(buffer)
    history.deserialize(state)
    history

  constructor: (@maxUndoEntries, @buffer) ->
    @nextCheckpointId = 0
    @undoStack = []
    @redoStack = []

  createCheckpoint: (snapshot, isBoundary) ->
    checkpoint = new Checkpoint(@nextCheckpointId++, snapshot, isBoundary)
    @undoStack.push(checkpoint)
    checkpoint.id

  groupChangesSinceCheckpoint: (checkpointId, markerSnapshotAfter, deleteCheckpoint=false) ->
    checkpointIndex = null
    markerSnapshotBefore = null
    patchesSinceCheckpoint = []

    for entry, i in @undoStack by -1
      break if checkpointIndex?

      switch entry.constructor
        when Checkpoint
          if entry.id is checkpointId
            checkpointIndex = i
            markerSnapshotBefore = entry.snapshot
          else if entry.isBoundary
            return false
        when Transaction
          patchesSinceCheckpoint.unshift(entry.patch)
        when Patch
          patchesSinceCheckpoint.unshift(entry)
        else
          throw new Error("Unexpected undo stack entry type: #{entry.constructor.name}")

    if checkpointIndex?
      composedPatches = Patch.compose(patchesSinceCheckpoint)
      if patchesSinceCheckpoint.length > 0
        @undoStack.splice(checkpointIndex + 1)
        @undoStack.push(new Transaction(markerSnapshotBefore, composedPatches, markerSnapshotAfter))
      if deleteCheckpoint
        @undoStack.splice(checkpointIndex, 1)
      composedPatches
    else
      false

  enforceUndoStackSizeLimit: ->
    if @undoStack.length > @maxUndoEntries
      @undoStack.splice(0, @undoStack.length - @maxUndoEntries)

  applyGroupingInterval: (groupingInterval) ->
    topEntry = @undoStack[@undoStack.length - 1]
    previousEntry = @undoStack[@undoStack.length - 2]

    if topEntry instanceof Transaction
      topEntry.groupingInterval = groupingInterval
    else
      return

    return if groupingInterval is 0

    if previousEntry instanceof Transaction and topEntry.shouldGroupWith(previousEntry)
      @undoStack.splice(@undoStack.length - 2, 2, topEntry.groupWith(previousEntry))

  pushChange: (change) ->
    @undoStack.push(Patch.hunk(change))
    @clearRedoStack()

  popUndoStack: ->
    snapshotBelow = null
    patch = null
    spliceIndex = null

    for entry, i in @undoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when Checkpoint
          if entry.isBoundary
            return false
        when Transaction
          snapshotBelow = entry.markerSnapshotBefore
          patch = Patch.invert(entry.patch)
          spliceIndex = i
        when Patch
          patch = Patch.invert(entry)
          spliceIndex = i
        else
          throw new Error("Unexpected entry type when popping undoStack: #{entry.constructor.name}")

    if spliceIndex?
      @redoStack.push(@undoStack.splice(spliceIndex).reverse()...)
      {
        snapshot: snapshotBelow
        patch: patch
      }
    else
      false

  popRedoStack: ->
    snapshotBelow = null
    patch = null
    spliceIndex = null

    for entry, i in @redoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when Checkpoint
          if entry.isBoundary
            throw new Error("Invalid redo stack state")
        when Transaction
          snapshotBelow = entry.markerSnapshotAfter
          patch = entry.patch
          spliceIndex = i
        when Patch
          patch = entry
          spliceIndex = i
        else
          throw new Error("Unexpected entry type when popping redoStack: #{entry.constructor.name}")

    while @redoStack[spliceIndex - 1] instanceof Checkpoint
      spliceIndex--

    if spliceIndex?
      @undoStack.push(@redoStack.splice(spliceIndex).reverse()...)
      {
        snapshot: snapshotBelow
        patch: patch
      }
    else
      false

  truncateUndoStack: (checkpointId) ->
    snapshotBelow = null
    spliceIndex = null
    patchesSinceCheckpoint = []

    for entry, i in @undoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when Checkpoint
          if entry.id is checkpointId
            snapshotBelow = entry.snapshot
            spliceIndex = i
          else if entry.isBoundary
            return false
        when Transaction
          patchesSinceCheckpoint.push(Patch.invert(entry.patch))
        else
          patchesSinceCheckpoint.push(Patch.invert(entry))

    if spliceIndex?
      @undoStack.splice(spliceIndex)
      {
        snapshot: snapshotBelow
        patch: Patch.compose(patchesSinceCheckpoint)
      }
    else
      false

  clearUndoStack: ->
    @undoStack.length = 0

  clearRedoStack: ->
    @redoStack.length = 0

  toString: ->
    output = ''
    for entry in @undoStack
      switch entry.constructor
        when Checkpoint
          output += "Checkpoint, "
        when Transaction
          output += "Transaction, "
        when Patch
          output += "Patch, "
        else
          output += "Unknown {#{JSON.stringify(entry)}}, "
    '[' + output.slice(0, -2) + ']'

  serialize: (options) ->
    version: SerializationVersion
    nextCheckpointId: @nextCheckpointId
    undoStack: @serializeStack(@undoStack, options)
    redoStack: @serializeStack(@redoStack, options)
    maxUndoEntries: @maxUndoEntries

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @nextCheckpointId = state.nextCheckpointId
    @maxUndoEntries = state.maxUndoEntries
    @undoStack = @deserializeStack(state.undoStack)
    @redoStack = @deserializeStack(state.redoStack)

  ###
  Section: Private
  ###

  getCheckpointIndex: (checkpointId) ->
    for entry, i in @undoStack by -1
      if entry instanceof Checkpoint and entry.id is checkpointId
        return i
    return null

  serializeStack: (stack, options) ->
    for entry in stack
      switch entry.constructor
        when Checkpoint
          {
            type: 'checkpoint'
            id: entry.id
            snapshot: @serializeSnapshot(entry.snapshot, options)
            isBoundary: entry.isBoundary
          }
        when Transaction
          {
            type: 'transaction'
            markerSnapshotBefore: @serializeSnapshot(entry.markerSnapshotBefore, options)
            markerSnapshotAfter: @serializeSnapshot(entry.markerSnapshotAfter, options)
            patch: entry.patch.serialize()
          }
        when Patch
          {
            type: 'patch'
            content: entry.serialize()
          }
        else
          throw new Error("Unexpected undoStack entry type during serialization: #{entry.constructor.name}")

  deserializeStack: (stack) ->
    for entry in stack
      switch entry.type
        when 'checkpoint'
          new Checkpoint(
            entry.id
            MarkerLayer.deserializeSnapshot(entry.snapshot)
            entry.isBoundary
          )
        when 'transaction'
          new Transaction(
            MarkerLayer.deserializeSnapshot(entry.markerSnapshotBefore)
            Patch.deserialize(entry.patch)
            MarkerLayer.deserializeSnapshot(entry.markerSnapshotAfter)
          )
        when 'patch'
          Patch.deserialize(entry.content)
        else
          throw new Error("Unexpected undoStack entry type during deserialization: #{entry.type}")

  serializeSnapshot: (snapshot, options) ->
    return unless options.markerLayers

    layers = {}
    for id, snapshot of snapshot when @buffer.getMarkerLayer(id)?.persistent
      layers[id] = snapshot
    layers
