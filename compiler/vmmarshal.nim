#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Implements marshaling for the VM.

import streams, json, intsets, tables, ast, astalgo, idents, types, msgs

proc ptrToInt(x: PNode): int {.inline.} =
  result = cast[int](x) # don't skip alignment

proc getField(n: PNode; position: int): PSym =
  case n.kind
  of nkRecList:
    for i in countup(0, sonsLen(n) - 1):
      result = getField(n.sons[i], position)
      if result != nil: return
  of nkRecCase:
    result = getField(n.sons[0], position)
    if result != nil: return
    for i in countup(1, sonsLen(n) - 1):
      case n.sons[i].kind
      of nkOfBranch, nkElse:
        result = getField(lastSon(n.sons[i]), position)
        if result != nil: return
      else: internalError(n.info, "getField(record case branch)")
  of nkSym:
    if n.sym.position == position: result = n.sym
  else: discard

proc storeAny(s: var string; t: PType; a: PNode; stored: var IntSet)

proc storeObj(s: var string; typ: PType; x: PNode; stored: var IntSet) =
  internalAssert x.kind == nkObjConstr
  let start = 1
  for i in countup(start, sonsLen(x) - 1):
    if i > start: s.add(", ")
    var it = x.sons[i]
    if it.kind == nkExprColonExpr:
      internalAssert it.sons[0].kind == nkSym
      let field = it.sons[0].sym
      s.add(escapeJson(field.name.s))
      s.add(": ")
      storeAny(s, field.typ, it.sons[1], stored)
    elif typ.n != nil:
      let field = getField(typ.n, i)
      s.add(escapeJson(field.name.s))
      s.add(": ")
      storeAny(s, field.typ, it, stored)

proc skipColon*(n: PNode): PNode =
  result = n
  if n.kind == nkExprColonExpr:
    result = n.sons[1]

proc storeAny(s: var string; t: PType; a: PNode; stored: var IntSet) =
  case t.kind
  of tyNone: assert false
  of tyBool: s.add($(a.intVal != 0))
  of tyChar:
    let ch = char(a.intVal)
    if ch < '\128':
      s.add(escapeJson($ch))
    else:
      s.add($int(ch))
  of tyArray, tySequence:
    if t.kind == tySequence and a.kind == nkNilLit: s.add("null")
    else:
      s.add("[")
      for i in 0 .. a.len-1:
        if i > 0: s.add(", ")
        storeAny(s, t.elemType, a[i], stored)
      s.add("]")
  of tyTuple:
    s.add("{")
    for i in 0..<t.len:
      if i > 0: s.add(", ")
      s.add("\"Field" & $i)
      s.add("\": ")
      storeAny(s, t.sons[i], a[i].skipColon, stored)
    s.add("}")
  of tyObject:
    s.add("{")
    storeObj(s, t, a, stored)
    s.add("}")
  of tySet:
    s.add("[")
    for i in 0..<a.len:
      if i > 0: s.add(", ")
      if a[i].kind == nkRange:
        var x = copyNode(a[i][0])
        storeAny(s, t.lastSon, x, stored)
        while x.intVal+1 <= a[i][1].intVal:
          s.add(", ")
          storeAny(s, t.lastSon, x, stored)
          inc x.intVal
      else:
        storeAny(s, t.lastSon, a[i], stored)
    s.add("]")
  of tyRange, tyGenericInst, tyAlias: storeAny(s, t.lastSon, a, stored)
  of tyEnum:
    # we need a slow linear search because of enums with holes:
    for e in items(t.n):
      if e.sym.position == a.intVal:
        s.add e.sym.name.s.escapeJson
        break
  of tyPtr, tyRef:
    var x = a
    if isNil(x) or x.kind == nkNilLit: s.add("null")
    elif stored.containsOrIncl(x.ptrToInt):
      # already stored, so we simply write out the pointer as an int:
      s.add($x.ptrToInt)
    else:
      # else as a [value, key] pair:
      # (reversed order for convenient x[0] access!)
      s.add("[")
      s.add($x.ptrToInt)
      s.add(", ")
      storeAny(s, t.lastSon, a, stored)
      s.add("]")
  of tyString, tyCString:
    if a.kind == nkNilLit or a.strVal.isNil: s.add("null")
    else: s.add(escapeJson(a.strVal))
  of tyInt..tyInt64, tyUInt..tyUInt64: s.add($a.intVal)
  of tyFloat..tyFloat128: s.add($a.floatVal)
  else:
    internalError a.info, "cannot marshal at compile-time " & t.typeToString

proc storeAny*(s: var string; t: PType; a: PNode) =
  var stored = initIntSet()
  storeAny(s, t, a, stored)

proc loadAny(p: var JsonParser, t: PType,
             tab: var Table[BiggestInt, PNode]): PNode =
  case t.kind
  of tyNone: assert false
  of tyBool:
    case p.kind
    of jsonFalse: result = newIntNode(nkIntLit, 0)
    of jsonTrue: result = newIntNode(nkIntLit, 1)
    else: raiseParseErr(p, "'true' or 'false' expected for a bool")
    next(p)
  of tyChar:
    if p.kind == jsonString:
      var x = p.str
      if x.len == 1:
        result = newIntNode(nkIntLit, ord(x[0]))
        next(p)
        return
    elif p.kind == jsonInt:
      result = newIntNode(nkIntLit, getInt(p))
      next(p)
      return
    raiseParseErr(p, "string of length 1 expected for a char")
  of tyEnum:
    if p.kind == jsonString:
      for e in items(t.n):
        if e.sym.name.s == p.str:
          result = newIntNode(nkIntLit, e.sym.position)
          next(p)
          return
    raiseParseErr(p, "string expected for an enum")
  of tyArray:
    if p.kind != jsonArrayStart: raiseParseErr(p, "'[' expected for an array")
    next(p)
    result = newNode(nkBracket)
    while p.kind != jsonArrayEnd and p.kind != jsonEof:
      result.add loadAny(p, t.elemType, tab)
    if p.kind == jsonArrayEnd: next(p)
    else: raiseParseErr(p, "']' end of array expected")
  of tySequence:
    case p.kind
    of jsonNull:
      result = newNode(nkNilLit)
      next(p)
    of jsonArrayStart:
      next(p)
      result = newNode(nkBracket)
      while p.kind != jsonArrayEnd and p.kind != jsonEof:
        result.add loadAny(p, t.elemType, tab)
      if p.kind == jsonArrayEnd: next(p)
      else: raiseParseErr(p, "")
    else:
      raiseParseErr(p, "'[' expected for a seq")
  of tyTuple:
    if p.kind != jsonObjectStart: raiseParseErr(p, "'{' expected for an object")
    next(p)
    result = newNode(nkPar)
    var i = 0
    while p.kind != jsonObjectEnd and p.kind != jsonEof:
      if p.kind != jsonString:
        raiseParseErr(p, "string expected for a field name")
      next(p)
      if i >= t.len:
        raiseParseErr(p, "too many fields to tuple type " & typeToString(t))
      result.add loadAny(p, t.sons[i], tab)
      inc i
    if p.kind == jsonObjectEnd: next(p)
    else: raiseParseErr(p, "'}' end of object expected")
  of tyObject:
    if p.kind != jsonObjectStart: raiseParseErr(p, "'{' expected for an object")
    next(p)
    result = newNode(nkObjConstr)
    result.sons = @[newNode(nkEmpty)]
    while p.kind != jsonObjectEnd and p.kind != jsonEof:
      if p.kind != jsonString:
        raiseParseErr(p, "string expected for a field name")
      let ident = getIdent(p.str)
      let field = lookupInRecord(t.n, ident)
      if field.isNil:
        raiseParseErr(p, "unknown field for object of type " & typeToString(t))
      next(p)
      let pos = field.position + 1
      if pos >= result.sons.len:
        setLen(result.sons, pos + 1)
      let fieldNode = newNode(nkExprColonExpr)
      fieldNode.addSon(newSymNode(newSym(skField, ident, nil, unknownLineInfo())))
      fieldNode.addSon(loadAny(p, field.typ, tab))
      result.sons[pos] = fieldNode
    if p.kind == jsonObjectEnd: next(p)
    else: raiseParseErr(p, "'}' end of object expected")
  of tySet:
    if p.kind != jsonArrayStart: raiseParseErr(p, "'[' expected for a set")
    next(p)
    result = newNode(nkCurly)
    while p.kind != jsonArrayEnd and p.kind != jsonEof:
      result.add loadAny(p, t.lastSon, tab)
      next(p)
    if p.kind == jsonArrayEnd: next(p)
    else: raiseParseErr(p, "']' end of array expected")
  of tyPtr, tyRef:
    case p.kind
    of jsonNull:
      result = newNode(nkNilLit)
      next(p)
    of jsonInt:
      result = tab.getOrDefault(p.getInt)
      if result.isNil:
        raiseParseErr(p, "cannot load object with address " & $p.getInt)
      next(p)
    of jsonArrayStart:
      next(p)
      if p.kind == jsonInt:
        let idx = p.getInt
        next(p)
        result = loadAny(p, t.lastSon, tab)
        tab[idx] = result
      else: raiseParseErr(p, "index for ref type expected")
      if p.kind == jsonArrayEnd: next(p)
      else: raiseParseErr(p, "']' end of ref-address pair expected")
    else: raiseParseErr(p, "int for pointer type expected")
  of tyString, tyCString:
    case p.kind
    of jsonNull:
      result = newNode(nkNilLit)
      next(p)
    of jsonString:
      result = newStrNode(nkStrLit, p.str)
      next(p)
    else: raiseParseErr(p, "string expected")
  of tyInt..tyInt64, tyUInt..tyUInt64:
    if p.kind == jsonInt:
      result = newIntNode(nkIntLit, getInt(p))
      next(p)
      return
    raiseParseErr(p, "int expected")
  of tyFloat..tyFloat128:
    if p.kind == jsonFloat:
      result = newFloatNode(nkFloatLit, getFloat(p))
      next(p)
      return
    raiseParseErr(p, "float expected")
  of tyRange, tyGenericInst, tyAlias: result = loadAny(p, t.lastSon, tab)
  else:
    internalError "cannot marshal at compile-time " & t.typeToString

proc loadAny*(s: string; t: PType): PNode =
  var tab = initTable[BiggestInt, PNode]()
  var p: JsonParser
  open(p, newStringStream(s), "unknown file")
  next(p)
  result = loadAny(p, t, tab)
  close(p)
