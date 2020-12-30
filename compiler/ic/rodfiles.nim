#
#
#           The Nim Compiler
#        (c) Copyright 2020 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

type
  RodSection* = enum
    versionSection
    configSection
    filesSection
    stringsSection
    integersSection
    floatsSection
    topLevelSection
    bodiesSection
    symsSection
    typesSection

  RodFileError* = enum
    ok, tooBig, ioFailure, wrongHeader, wrongSection

  RodFile* = object
    f*: File
    currentSection*: RodSection # for error checking
    err*: RodFileError # little experiment to see if this works
                       # better than exceptions.

const
  RodVersion = 1
  cookie = [byte(0), byte('R'), byte('O'), byte('D'),
            byte(0), byte(0), byte(0), byte(RodVersion)]

proc storePrim*(f: var RodFile; s: string) =
  if f.err != ok: return
  if s.len >= high(int32):
    f.err = tooBig
    return
  var lenPrefix = int32(s.len)
  if writeBuffer(f.f, addr lenPrefix, sizeof(lenPrefix)) != sizeof(lenPrefix):
    f.err = ioFailure
  else:
    if s.len != 0:
      if writeBuffer(f.f, unsafeAddr(s[0]), s.len) != s.len:
        f.err = ioFailure

proc storePrim*[T](f: var RodFile; x: T) =
  if f.err != ok: return
  if writeBuffer(f.f, unsafeAddr(x), sizeof(x)) != sizeof(x):
    f.err = ioFailure

proc storeSeq*[T](f: var RodFile; s: seq[T]) =
  if f.err != ok: return
  if s.len >= high(int32):
    f.err = tooBig
    return
  var lenPrefix = int32(s.len)
  if writeBuffer(f.f, addr lenPrefix, sizeof(lenPrefix)) != sizeof(lenPrefix):
    f.err = ioFailure
  else:
    for i in 0..<s.len:
      storePrim(f, s[i])

proc loadPrim*(f: var RodFile; s: var string) =
  if f.err != ok: return
  var lenPrefix = int32(0)
  if readBuffer(f.f, addr lenPrefix, sizeof(lenPrefix)) != sizeof(lenPrefix):
    f.err = ioFailure
  else:
    s = newString(lenPrefix)
    if lenPrefix > 0:
      if readBuffer(f.f, unsafeAddr(s[0]), s.len) != s.len:
        f.err = ioFailure

proc loadPrim*[T](f: var RodFile; x: var T) =
  if f.err != ok: return
  if readBuffer(f.f, unsafeAddr(x), sizeof(x)) != sizeof(x):
    f.err = ioFailure

proc loadSeq*[T](f: var RodFile; s: var seq[T]) =
  if f.err != ok: return
  var lenPrefix = int32(0)
  if readBuffer(f.f, addr lenPrefix, sizeof(lenPrefix)) != sizeof(lenPrefix):
    f.err = ioFailure
  else:
    s = newSeq[T](lenPrefix)
    for i in 0..<lenPrefix:
      loadPrim(f, s[i])

proc storeHeader*(f: var RodFile) =
  if f.err != ok: return
  if f.f.writeBytes(cookie, 0, cookie.len) != cookie.len:
    f.err = ioFailure

proc loadHeader*(f: var RodFile) =
  if f.err != ok: return
  var thisCookie: array[cookie.len, byte]
  if f.f.readBytes(thisCookie, 0, thisCookie.len) != thisCookie.len:
    f.err = ioFailure
  elif thisCookie != cookie:
    f.err = wrongHeader

proc storeSection*(f: var RodFile; s: RodSection) =
  if f.err != ok: return
  assert f.currentSection == pred s
  f.currentSection = s
  storePrim(f, s)

proc loadSection*(f: var RodFile; expected: RodSection) =
  if f.err != ok: return
  var s: RodSection
  loadPrim(f, s)
  if expected != s:
    f.err = wrongSection

proc create*(filename: string): RodFile =
  if not open(result.f, filename, fmWrite):
    result.err = ioFailure

proc close*(f: var RodFile) = close(f.f)

proc open*(filename: string): RodFile =
  if not open(result.f, filename, fmRead):
    result.err = ioFailure
