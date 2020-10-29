#
#
#           The Nim Compiler
#        (c) Copyright 2020 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, tables]
import packed_ast, bitabs
import ".." / [ast, idents, lineinfos, msgs]

type
  Context = object
    thisModule: int32
    lastFile: FileIndex # remember the last lookup entry.
    lastLit: LitId
    filenames: Table[FileIndex, LitId]
    pendingTypes: seq[PType]
    pendingSyms: seq[PSym]
    typeMap: Table[int32, TypeId]  # ItemId.item -> TypeId
    symMap: Table[int32, SymId]    # ItemId.item -> SymId

proc toPackedNode*(n: PNode; ir: var PackedTree; c: var Context)
proc toPackedSym(s: PSym; ir: var PackedTree; c: var Context): SymId
proc toPackedType(t: PType; ir: var PackedTree; c: var Context): TypeId

proc flush(ir: var PackedTree; c: var Context) =
  ## serialize any pending types or symbols from the context
  while true:
    if c.pendingTypes.len > 0:
      discard toPackedType(c.pendingTypes.pop, ir, c)
    elif c.pendingSyms.len > 0:
      discard toPackedSym(c.pendingSyms.pop, ir, c)
    else:
      break

proc addItemId(tree: var PackedTree; id: ItemId; typ: TypeId; info: PackedLineInfo) =
  ## add an itemid to the tree; we trust that it's foreign
  let patchPos = tree.prepare(nkModuleRef, flags = {}, typ, info)
  tree.nodes.add Node(kind: nkInt32Lit, operand: id.module, info: info)
  tree.nodes.add Node(kind: nkInt32Lit, operand: id.item, info: info)
  tree.patch patchPos

proc toLitId(x: BiggestInt; ir: var PackedTree; c: var Context): LitId =
  # i think smaller integers aren't worth putting into a table
  # because there they become 32bit hash values on the heap...
  result = getOrIncl(ir.sh.integers, x)

proc toLitId(x: FileIndex; ir: var PackedTree; c: var Context): LitId =
  if x == c.lastFile:
    result = c.lastLit
  else:
    result = c.filenames.getOrDefault(x)
    if result == LitId(0):
      let p = msgs.toFullPath(ir.sh.config, x)
      result = getOrIncl(ir.sh.strings, p)
      c.filenames[x] = result
    c.lastFile = x
    c.lastLit = result

proc toPackedInfo(x: TLineInfo; ir: var PackedTree; c: var Context): PackedLineInfo =
  PackedLineInfo(line: x.line, col: x.col, file: toLitId(x.fileIndex, ir, c))

proc addMissing(c: var Context; p: PSym) =
  if p.itemId.module == c.thisModule:
      if not p.itemId.item in c.symMap:
        c.pendingSyms.add p

proc addMissing(c: var Context; p: PType) =
  if p.uniqueId.module == c.thisModule:
      if not p.uniqueId.item in c.typeMap:
        c.pendingTypes.add p

proc toPackedType(t: PType; ir: var PackedTree; c: var Context): TypeId =
  template info: PackedLineInfo =
    # too bad the most variant part of the operation comes first...
    (if t.n.isNil: TLineInfo() else: t.n.info).toPackedInfo(ir, c)

  assert t.itemId.module == c.thisModule   # should we even be here?

  # short-circuit if we already have the TypeId
  result = getOrDefault(c.typeMap, t.uniqueId.item, TypeId(-1))
  if result != TypeId(-1): return

  ir.sh.types.add:
    PackedType(kind: t.kind, flags: t.flags, info: info,
               size: t.size, align: t.align, nonUniqueId: t.itemId,
               paddingAtEnd: t.paddingAtEnd, lockLevel: t.lockLevel,
               node: newTreeFrom(ir))
  result = TypeId(ir.sh.types.high)
  c.typeMap[t.itemId.item] = result
  template p: PackedType = ir.sh.types[int result]

  for op, s in pairs t.attachedOps:
    c.addMissing s
    p.attachedOps[op] = s.itemId

  p.typeInst = t.typeInst.toPackedType(ir, c)

  for kid in items t.sons:
    p.types.add kid.toPackedType(ir, c)

  for _, s in items t.methods:
    c.addMissing s
    p.methods.add s.itemId

  if not t.sym.isNil:
    c.addMissing t.sym
    p.sym = t.sym.itemId

  if not t.n.isNil:
    p.nodekind = t.n.kind
    p.nodeflags = t.n.flags
    t.n.toPackedNode(p.node, c)

  ir.flush c

proc toPackedSym(s: PSym; ir: var PackedTree; c: var Context): SymId =
  result = SymId(0)

proc toPackedSymNode(n: PNode; ir: var PackedTree; c: var Context) =
  assert n.kind == nkSym
  template info: PackedLineInfo = toPackedInfo(n.info, ir, c)
  if n.sym.itemId.module == c.thisModule:
    # it is a symbol that belongs to the module we're currently
    # packing:
    ir.addSym(n.sym.toPackedSym(ir, c), info)
  else:
    # store it as an external module reference:
    ir.addItemId(n.sym.itemId, n.typ.toPackedType(ir, c), info)

proc toPackedNode*(n: PNode; ir: var PackedTree; c: var Context) =
  template info: PackedLineInfo = toPackedInfo(n.info, ir, c)

  case n.kind
  of nkNone, nkEmpty, nkNilLit:
    ir.nodes.add Node(kind: n.kind, flags: n.flags, operand: 0,
                      typeId: toPackedType(n.typ, ir, c), info: info)
  of nkIdent:
    ir.nodes.add Node(kind: n.kind, flags: n.flags,
                      operand: int32 getOrIncl(ir.sh.strings, n.ident.s),
                      typeId: toPackedType(n.typ, ir, c), info: info)
  of nkSym:
    toPackedSymNode(n, ir, c)
  of directIntLit:
    ir.nodes.add Node(kind: n.kind, flags: n.flags, operand: int32(n.intVal),
                      typeId: toPackedType(n.typ, ir, c), info: info)
  of externIntLit:
    ir.nodes.add Node(kind: n.kind, flags: n.flags,
                      operand: int32 getOrIncl(ir.sh.integers, n.intVal),
                      typeId: toPackedType(n.typ, ir, c), info: info)
  of nkStrLit..nkTripleStrLit:
    ir.nodes.add Node(kind: n.kind, flags: n.flags,
                      operand: int32 getOrIncl(ir.sh.strings, n.strVal),
                      typeId: toPackedType(n.typ, ir, c), info: info)
  of nkFloatLit..nkFloat128Lit:
    ir.nodes.add Node(kind: n.kind, flags: n.flags,
                      operand: int32 getOrIncl(ir.sh.floats, n.floatVal),
                      typeId: toPackedType(n.typ, ir, c), info: info)
  else:
    let patchPos = ir.prepare(n.kind, n.flags,
                              toPackedType(n.typ, ir, c), info)
    for i in 0..<n.len:
      toPackedNode(n[i], ir, c)
    ir.patch patchPos

proc moduleToIr*(n: PNode; ir: var PackedTree; module: PSym) =
  var c = Context(thisModule: module.itemId.module)
  toPackedNode(n, ir, c)
