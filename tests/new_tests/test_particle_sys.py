from lox_helper import run_lox


EXPECTED = [
    "3",      # emit(3)
    "true",   # update() 1 — all alive (age 1 < life 2)
    "3",
    "false",  # update() 2 — all dead (age 2 >= life 2), swap-removed
    "0",
    "2",      # emit(2) — recycled from the pool
    "true",   # update() 1
    "false",  # update() 2
    "0",
    # Emitters.queue() one-shot burst. Also guards the field/method name
    # collision: a field named `queue` would shadow the queue() method and make
    # es.queue(...) fail with "Can only call functions and classes".
    "1",      # queued, delay not yet elapsed
    "0",      # no active emitters yet
    "1",      # still pending after one update
    "0",      # delay elapsed -> promoted, nothing pending
    "1",      # one active emitter
    "0",      # particles died -> exhausted emitter dropped
]


def test_particle_sys_pool_and_removal():
    # Exercises particle_sys swap-remove removal, pool reuse, and the queue()
    # one-shot path (headless: the module only imports random/math, no window).
    for force in (True, False):
        lines = run_lox("particle_sys.lox", force_compile=force)
        assert lines[-1] == "nil"      # top-level nil return
        assert lines[:-1] == EXPECTED
