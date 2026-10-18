import os
import subprocess

from lox_helper import run_lox, ODLOX, TESTS_DIR

# `from m import type A`: resolved by the type checker, never imported at
# runtime -- so it can name a class across an import cycle. Fixtures are
# the to_*.lox files (to_game.lox <-> to_actor.lox form the cycle).


def test_type_only_import_across_cycle_runs_without_false_positive():
    lines = run_lox("to_cycle_ok.lox", force_compile=True)
    assert "2" in lines, lines
    # to_game.lox passes its own `this` to a Game-typed parameter whose
    # type came from to_actor's (separately compiled) view of Game.
    assert not any("Warning" in line for line in lines), lines


def test_type_only_import_checks_argument_type():
    lines = run_lox("to_cycle_bad_call.lox", force_compile=True)
    assert any("expected Game, got int" in line for line in lines), lines
    assert "1" in lines, lines


def test_type_only_name_used_as_value_is_compile_error():
    path = os.path.join("lox", "to_value_use.lox")
    r = subprocess.run([ODLOX, path], capture_output=True, cwd=TESTS_DIR)
    assert r.returncode == 65, r.stdout
    assert b"'Game' is imported for type annotations only." in r.stdout


def test_type_only_import_does_not_load_module():
    lines = run_lox("to_no_runtime_import.lox")
    assert "done" in lines, lines
    assert not any("to_noisy loaded" in line for line in lines), lines


def test_class_name_takes_precedence_over_native_type_name():
    lines = run_lox("to_sound_class.lox")
    assert any("expected Sound, got int" in line for line in lines), lines
    assert not any("expected Sound, got Sound" in line for line in lines), lines


def test_strict_types_fails_on_type_only_import_mismatch():
    path = os.path.join("lox", "to_cycle_bad_call.lox")
    r = subprocess.run([ODLOX, "--strict-types", "--force-compile", path], capture_output=True, cwd=TESTS_DIR)
    assert r.returncode == 65, r.stdout
    assert b"expected Game, got int" in r.stdout
