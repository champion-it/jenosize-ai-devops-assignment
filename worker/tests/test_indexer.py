from worker.indexer.main import extract_title


def test_title_comes_from_the_first_heading():
    assert extract_title("# Password Reset\n\nbody", "fallback") == "Password Reset"


def test_fallback_is_used_without_a_heading():
    assert extract_title("no heading here", "Vpn Access") == "Vpn Access"


def test_later_headings_are_ignored():
    text = "intro\n\n# First\n\n# Second"
    assert extract_title(text, "fallback") == "First"
