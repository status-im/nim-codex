import std/macros
import pkg/questionable
import pkg/questionable/operators

export questionable

proc `as`*[T](value: T, U: type): ?U =
  ## Casts a value to another type, returns an Option.
  ## When the cast succeeds, the option will contain the casted value.
  ## When the cast fails, the option will have no value.

  # In Nim 2.0.x, check 42.some as int == none(int)
  # Maybe because some 42.some looks like Option[Option[int]]
  # So we check first that the value is an option of the expected type.
  # In that case, we do not need to do anything, just return the value as it is.
  when value is Option[U]:
    return value

  when value is U:
    return some value
  elif value is ref object:
    if value of U:
      return some U(value)

Option.liftBinary `as`

# Template that wraps type with `Option[]` only if it is already not `Option` type
template WrapOption*(input: untyped): type =
  when input is Option:
    input
  else:
    Option[input]

macro createType(t: typedesc): untyped =
  var objectType = getType(t)

  # Work around for https://github.com/nim-lang/Nim/issues/23112
  while objectType.kind == nnkBracketExpr and objectType[0].eqIdent"typeDesc":
    objectType = getType(objectType[1])

  expectKind(objectType, NimNodeKind.nnkObjectTy)
  var fields = nnkRecList.newTree()

  # Generates the list of fields that are wrapped in `Option[T]`.
  # Technically wrapped with `WrapOption` which is template used to prevent
  # re-wrapping already filed which is `Option[T]`.
  for field in objectType[2]:
    let fieldType = getTypeInst(field)
    let newFieldNode = nnkIdentDefs.newTree(
      ident($field), nnkCall.newTree(ident("WrapOption"), fieldType), newEmptyNode()
    )

    fields.add(newFieldNode)

  # Creates new object type T with the fields lists from steps above.
  let tSym = genSym(nskType, "T")
  nnkStmtList.newTree(
    nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        tSym,
        newEmptyNode(),
        nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), fields),
      )
    ),
    tSym,
  )

template Optionalize*(t: typed): untyped =
  ## Takes object type and wraps all the first level fields into
  ## Option type unless it is already Option type.
  createType(t)
