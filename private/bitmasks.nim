import macros

macro bitmask*(set_type, enum_type, ctype, body: untyped): stmt =
    # bitmask Set, Enum, Ctype:
    #   foo = hello
    #   bar = world

    #---- create types
    type Enum_pairs = seq[tuple[key, value: Nim_node]]
    proc asgn_to_pairs(body: Nim_node): Enum_pairs =
        result.new_seq 0
        for asgn in body:
            result.add((asgn[0], asgn[1]))

    let enum_pairs = asgn_to_pairs(body)

    let enumerants = new_tree(nnk_enum_ty, new_empty_node())
    for kv in enum_pairs:
        enumerants.add kv.key

    # type
    #   Enum* = enum
    #       foo
    #       bar
    #   Set* = set[Enum]
    let type_def = new_tree(nnk_type_section,
        new_tree(nnk_type_def,
            new_tree(nnk_pragma_expr,
                new_tree(nnk_postfix, new_ident_node("*"), enum_type),
                new_tree(nnk_pragma, new_ident_node("pure")),
            ),
            new_empty_node(),
            enumerants
        ),
        new_tree(nnk_type_def,
            new_tree(nnk_postfix, new_ident_node("*"), set_type),
            new_empty_node(),
            new_tree(nnk_bracket_expr, new_ident_node("set"), enum_type)
        )
    )

    #---- create converter
    proc pairs_to_case(eps: Enum_pairs, topic: Nim_node, enum_type: Nim_node): Nim_node =
        result = new_tree(nnk_case_stmt, topic)
        for kv in eps:
            result.add new_tree(nnk_of_branch,
                new_tree(nnk_dot_expr, enum_type, kv.key),
                new_stmt_list(
                    new_tree(nnk_asgn,
                        new_ident_node("result"),
                        new_tree(nnk_infix, new_ident_node("or"), new_ident_node("result"), kv.value)
                    )
                )
            )

    let param = gen_sym(nsk_param, "flags")
    let for_var = gen_sym(nsk_for_var, "flag")
    let enum_case = enum_pairs.pairs_to_case(for_var, enum_type)

    # converter to_bitmask*(flags: Set): Ctype =
    #   for flag in flags:
    #       case flag
    #       of Enum.foo: result = result or hello
    #       of Enum.bar: result = result or world
    let converter_def = new_tree(nnk_converter_def,
        new_tree(nnk_postfix, new_ident_node("*"), new_ident_node("to_bitmask")),
        new_empty_node(),
        new_empty_node(),
        new_tree(nnk_formal_params,
            ctype,
            new_tree(nnk_ident_defs, param, set_type, new_empty_node())
        ),
        new_empty_node(),
        new_empty_node(),
        new_stmt_list(
            new_tree(nnk_for_stmt, for_var, param, new_stmt_list(enum_case))
        )
    )

    result = new_stmt_list(type_def, converter_def)
    when is_main_module:
        echo tree_repr(result)

when is_main_module:
    dump_tree:
        type
            Env_flags* {.pure.} = enum
                fixed_map
                rd_only
            Env_flags_set* = set[Env_flags]

        converter to_bitmask*(flags: Env_flags_set): cuint =
            for flag in flags:
                case flag
                of Env_flags.fixed_map: result = result or 0b01
                of Env_flags.rd_only  : result = result or 0b10

    macro bitmask_dump(set_type, enum_type, ctype, body: untyped): stmt =
        echo "------------------------------"
        echo tree_repr(set_type)
        echo tree_repr(enum_type)
        echo tree_repr(ctype)
        echo tree_repr(body)
        echo "------------------------------"
        new_stmt_list()

    bitmask_dump Env_flags_set, Env_flags, cuint:
        fixed_map = 0b01
        rd_only   = 0b10

    #---- real try
    bitmask Env_flags_set, Env_flags, cuint:
        fixed_map = 0b01
        rd_only   = 0b10

    proc print(flags: cuint, raw: Env_flags_set) = echo flags, " ", $raw
    proc print(flags: Env_flags_set) = print(flags, flags)


    var flags = {}.Env_flags_set
    flags.print
    flags.incl Env_flags.rd_only
    flags.print
    flags.incl Env_flags.fixed_map
    flags.print
    flags.excl Env_flags.rd_only
    flags.print

