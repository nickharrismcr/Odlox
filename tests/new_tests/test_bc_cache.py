import os

from lox_helper import LOX_DIR, run_lox

CACHE_PATH = os.path.join(LOX_DIR, "__loxcache__", "bc_cache_module.lxc")


def test_bc_cache_roundtrip_cold_and_warm_match():
    """Bytecode cache correctness (docs/plans/bytecode-cache.md): a cache's
    real failure mode is silent corruption, not a crash, so this asserts
    exact output both cold (no .lxc yet, compiles bc_cache_module.lox from
    source) and warm (immediately after, hits the .lxc the cold run wrote) --
    any divergence between the two runs is definitionally cache corruption.
    """
    if os.path.exists(CACHE_PATH):
        os.remove(CACHE_PATH)

    cold = run_lox("bc_cache_roundtrip_stress.lox")
    assert cold[0] == "0"
    assert cold[1] == "bc_cache_roundtrip_stress complete"
    assert os.path.exists(CACHE_PATH), "expected a cold run to write a fresh .lxc cache"

    warm = run_lox("bc_cache_roundtrip_stress.lox")
    assert warm == cold


def test_bc_cache_force_compile_ignores_stale_cache():
    """--force-compile must bypass the cache read even when a valid, fresh
    .lxc is present -- mirrors glox's own -f semantics (see
    docs/plans/bytecode-cache.md)."""
    run_lox("bc_cache_roundtrip_stress.lox")  # ensure a cache exists
    assert os.path.exists(CACHE_PATH)

    forced = run_lox("bc_cache_roundtrip_stress.lox", force_compile=True)
    assert forced[0] == "0"
    assert forced[1] == "bc_cache_roundtrip_stress complete"
