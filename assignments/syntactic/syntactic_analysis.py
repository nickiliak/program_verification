#!/usr/bin/env python3
import logging
import re
import sys
from pathlib import Path

import tree_sitter
import tree_sitter_java

import jpamb

JAVA_LANGUAGE = tree_sitter.Language(tree_sitter_java.language())

def check_assert(body):
    assert_q = tree_sitter.Query(JAVA_LANGUAGE, """(assert_statement) @assert""")
    assert_q_with_false = tree_sitter.Query(
        JAVA_LANGUAGE, """(assert_statement (false)) @assert.false"""
    )
    assert_q_with_true = tree_sitter.Query(
        JAVA_LANGUAGE, """(assert_statement (true)) @assert.true"""
    )

    assert_found = any(
        capture_name == "assert"
        for capture_name, _ in tree_sitter.QueryCursor(assert_q).captures(body).items()
    )

    assert_false_found = any(
        capture_name == "assert.false"
        for capture_name, _ in tree_sitter.QueryCursor(assert_q_with_false).captures(body).items()
    )

    assert_true_found = any(
        capture_name == "assert.true"
        for capture_name, _ in tree_sitter.QueryCursor(assert_q_with_true).captures(body).items()
    )

    if assert_false_found:
        print("assertion error;found")
        return "yes"
    elif assert_true_found:
        print("assertion error;not-found")
        return "no"
    elif assert_found:
        return "maybe"


def check_divide(body):
    divide_q = tree_sitter.Query(
        JAVA_LANGUAGE,
        """
    (binary_expression
    operator: "/"
    ) @divide
    """,
    )

    divide_found = any(
        capture_name == "divide"
        for capture_name, _ in tree_sitter.QueryCursor(divide_q).captures(body).items()
    )

    if divide_found:
        print("divide by zero;found")
        return "yes"
    else:
        print("divide by zero;not-found")
        return "no"

    # for q in jpamb.QUERIES:
    #     if q != "assertion error" and q != "divide by zero":
    #         print(f"{q};skip")




def check_loops(body):
    # Updated query matching boolean_literal and for(;;) loops
    infinite_loop_q = tree_sitter.Query(
        JAVA_LANGUAGE,
        """
        [
          (while_statement
            condition: (parenthesized_expression
              (boolean_literal) @bool
              (#eq? @bool "true")
            )
          )
          (for_statement
            condition: None
          )
        ] @while.infinite
        """,
    )

    cursor = tree_sitter.QueryCursor()
    captures = cursor.captures(infinite_loop_q, body)

    # captures is a dict mapping capture_name -> list of Nodes in py-tree-sitter 0.22+
    infinite_loop_found = "while.infinite" in captures and len(captures["while.infinite"]) > 0

    if infinite_loop_found:
        print("infinite loop;found")
        return "yes"
    else:
        print("infinite loop;not-found")
        return "no"

def main():
    methodid = jpamb.getmethodid(
        "syntaxer",
        "1.0",
        "nickiliak",
        ["syntactic", "python"],
        for_science=True,
    )

    parser = tree_sitter.Parser(JAVA_LANGUAGE)

    log = logging
    log.basicConfig(level=logging.DEBUG)

    suite, _ = jpamb.setup()

    srcfile = suite.sourcefile(methodid.classname).relative_to(Path.cwd())

    with open(srcfile, "rb") as f:
        log.debug("parse sourcefile %s", srcfile)
        tree = parser.parse(f.read())

    simple_classname = str(methodid.classname.name)

    log.debug(f"{simple_classname}")

    # To figure out how to write these you can consult the
    # https://tree-sitter.github.io/tree-sitter/playground
    class_q = tree_sitter.Query(
        JAVA_LANGUAGE,
        f"""
        (class_declaration 
            name: ((identifier) @class-name 
                   (#eq? @class-name "{simple_classname}"))) @class
    """,
    )

    for node in tree_sitter.QueryCursor(class_q).captures(tree.root_node)["class"]:
        break
    else:
        log.error(f"could not find a class of name {simple_classname} in {srcfile}")

        sys.exit(-1)

    # log.debug("Found class %s", node.range)

    method_name = methodid.extension.name

    method_q = tree_sitter.Query(
        JAVA_LANGUAGE,
        f"""
        (method_declaration name: 
          ((identifier) @method-name (#eq? @method-name "{method_name}"))
        ) @method
    """,
    )

    for snode in tree_sitter.QueryCursor(method_q).captures(node)["method"]:
        if not (p := snode.child_by_field_name("parameters")):
            log.debug(f"Could not find parameteres of {method_name}")
            continue

        params = [c for c in p.children if c.type == "formal_parameter"]

        if len(params) != len(methodid.extension.params):
            continue

        log.debug(methodid.extension.params)
        log.debug(params)

        for tn, t in zip(methodid.extension.params, params):
            if (tp := t.child_by_field_name("type")) is None:
                break

            if tp.text is None:
                break

            # todo check for type.
        else:
            break
    else:
        log.warning(
            f"could not find a method of name {method_name} in {simple_classname}"
        )
        sys.exit(-1)

    body = node.child_by_field_name("body")
    assert body and body.text
    for t in body.text.splitlines():
        log.debug("line: %s", t.decode())



    # Make predictions (improve these by looking at the Java code!)
    ok_chance = "yes"
    out_of_bounds_chance = "-1.23"
    divide_by_zero_chance = check_divide(body)
    assertion_error_chance = check_assert(body)
    null_pointer_chance = "maybe"
    infinite_loop_chance = check_loops(body)

    # Output predictions for all 6 possible outcomes
    print(f"ok;{ok_chance}")
    print(f"divide by zero;{divide_by_zero_chance}")
    print(f"assertion error;{assertion_error_chance}")
    print(f"out of bounds;{out_of_bounds_chance}")
    print(f"null pointer;{null_pointer_chance}")
    print(f"*;{infinite_loop_chance}")

    sys.exit(0)
main()
