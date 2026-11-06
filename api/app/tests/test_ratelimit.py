from api.app.ratelimit import FixedWindowRateLimiter


def test_requests_under_the_limit_are_allowed():
    limiter = FixedWindowRateLimiter(3)
    assert all(limiter.allow("1.2.3.4", now=0) for _ in range(3))


def test_requests_over_the_limit_are_rejected():
    limiter = FixedWindowRateLimiter(2)
    limiter.allow("1.2.3.4", now=0)
    limiter.allow("1.2.3.4", now=0)
    assert limiter.allow("1.2.3.4", now=0) is False


def test_window_resets_after_a_minute():
    limiter = FixedWindowRateLimiter(1)
    assert limiter.allow("1.2.3.4", now=0) is True
    assert limiter.allow("1.2.3.4", now=10) is False
    assert limiter.allow("1.2.3.4", now=61) is True


def test_clients_are_counted_independently():
    limiter = FixedWindowRateLimiter(1)
    assert limiter.allow("1.1.1.1", now=0) is True
    assert limiter.allow("2.2.2.2", now=0) is True


def test_zero_limit_disables_the_check():
    limiter = FixedWindowRateLimiter(0)
    assert all(limiter.allow("1.2.3.4", now=0) for _ in range(100))
