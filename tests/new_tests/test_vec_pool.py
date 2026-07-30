from lox_helper import run_lox


def test_vec_pool_reuse_correctness():
    """Stress-tests the vec2/3/4 pool allocator (docs/plans/pool-allocator.md):
    thousands of allocations forcing repeated free-list reuse must never leak
    a stale field value from whatever previously occupied the same memory."""
    lines = run_lox("pool_reuse_stress.lox")
    assert lines[0] == "0"
    assert lines[1] == "pool_reuse_stress complete"
