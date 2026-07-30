from lox_helper import run_lox


def test_sound_native_layer_smoke():
    """Native `sound` module (docs/plans/sound.md): device lifecycle, Sound,
    and Music objects, run end to end with no crash/hang. Audible playback
    can't be asserted on here -- this checks what the API itself reports
    (is_ready()/is_playing() transitions, structural values) plus clean,
    idempotent unload/close."""
    lines = run_lox("sound_smoke.lox")
    assert lines == [
        "false",  # is_ready() before init()
        "true",  # is_ready() after init()
        "false",  # Sound.is_playing() before play()
        "true",  # Sound.is_playing() after play()
        "false",  # Sound.is_playing() after stop()
        "true",  # Music.time_length() > 0.0
        "true",  # Music.is_looping() after set_looping(true)
        "false",  # Music.is_looping() after set_looping(false)
        "true",  # get_master_volume() > 0.7 after set_master_volume(0.8)
        "false",  # is_ready() after close()
        "sound_smoke complete",
        "nil",  # the script's own top-level expression result
    ]


def test_sound_manager_smoke():
    """modules/sound_mgr.lox's SoundManager: the two pieces of real policy
    it adds over the native layer -- exclusivity groups and the mute
    switch."""
    lines = run_lox("sound_mgr_smoke.lox")
    assert lines == [
        "false",  # "a" stopped when "b" (same group) started playing
        "true",  # "b" playing
        "true",  # "c" (no group) playing, unaffected by group activity
        "true",  # play_if_not() doesn't restart an already-playing sound
        "false",  # "a" stopped by set_muted(true)
        "false",  # "b" stopped by set_muted(true)
        "false",  # "c" stopped by set_muted(true)
        "true",  # is_muted()
        "false",  # play() while muted is a no-op
        "true",  # play() works again after set_muted(false)
        "sound_mgr_smoke complete",
        "nil",  # the script's own top-level expression result
    ]
