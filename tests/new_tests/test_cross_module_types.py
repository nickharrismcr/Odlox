import os
import subprocess

from lox_helper import run_lox, ODLOX, TESTS_DIR

# End-to-end cross-module type checking: the from-import/namespace-import
# consultation sites (typecheck_stmt.odin/types.odin/typecheck_class.odin/
# typecheck_expr.odin) driven by a *real* vm.Module_Resolver against real
# files on disk, not the fake in-memory resolver typecheck_test.odin uses.
# Each xm_*.lox fixture pairs a small module (alongside the entry script,
# same convention as module.lox/imports.lox) with a script that imports
# it and does something statically wrong -- deliberately written so the
# wrong call never crashes at runtime either, so the *only* observable
# effect (without --strict-types) is the warning itself.


def test_from_import_wrong_argument_type_warns():
    lines = run_lox("xm_from_import_bad_call.lox")
    assert any("expected int, got string" in line for line in lines), lines


def test_from_import_unknown_export_warns():
    lines = run_lox("xm_from_import_unknown_export.lox")
    assert any("xm_math' has no export 'subtract'" in line for line in lines), lines


def test_from_import_superclass_flattens_and_diagnoses_missing_method():
    lines = run_lox("xm_from_import_superclass_typo.lox")
    assert any("no method 'notAMethod'" in line for line in lines), lines
    # The inherited method (c.area(), only in xm_shapes.lox's own Shape,
    # never in Circle) must resolve cleanly -- the direct regression
    # check for the bug this whole effort started from (a cross-module
    # superclass used to make methods_uncertain suppress *every*
    # diagnostic for the subclass, inherited or not).
    assert not any("no method 'area'" in line for line in lines), lines


def test_namespace_import_wrong_argument_type_warns():
    lines = run_lox("xm_namespace_bad_call.lox")
    assert any("expected string, got int" in line for line in lines), lines


def test_strict_types_hard_fails_on_latent_cross_module_bug():
    # Before this work: from-imported functions were always Dynamic, so
    # this exact call never diagnosed at all, --strict-types included --
    # the fixture would compile and run silently under both. Now it's a
    # real, --strict-types-enforceable diagnostic.
    path = os.path.join("lox", "xm_from_import_bad_call.lox")

    lenient = subprocess.run([ODLOX, path], capture_output=True, cwd=TESTS_DIR)
    assert lenient.returncode == 0, lenient.stdout

    strict = subprocess.run([ODLOX, "--strict-types", path], capture_output=True, cwd=TESTS_DIR)
    assert strict.returncode == 65, strict.stdout
    assert b"expected int, got string" in strict.stdout
