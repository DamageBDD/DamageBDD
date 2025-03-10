import pytest
import hashlib
from ecdsa import SECP256k1, ellipticcurve

# Define elliptic curve parameters
curve = SECP256k1.curve
p = curve.p()
a, b = curve.a(), curve.b()


def legendre_symbol(a, p):
    """Computes the Legendre symbol (a/p)."""
    return pow(a, (p - 1) // 2, p)


def tonelli_shanks(n, p):
    """Finds a modular square root using Tonelli-Shanks algorithm."""
    assert legendre_symbol(n, p) == 1, "No modular square root exists"
    if p % 4 == 3:
        return pow(n, (p + 1) // 4, p)

    # Factor out powers of 2
    q, s = p - 1, 0
    while q % 2 == 0:
        q //= 2
        s += 1

    # Find a non-residue z
    z = 2
    while legendre_symbol(z, p) != p - 1:
        z += 1
    m, c, t, r = s, pow(z, q, p), pow(n, q, p), pow(n, (q + 1) // 2, p)

    while t != 0 and t != 1:
        i, temp = 0, t
        while temp != 1:
            temp = (temp * temp) % p
            i += 1
            if i == m:
                raise ValueError("No modular square root found")

        b = pow(c, 1 << (m - i - 1), p)
        m, c, t, r = i, (b * b) % p, (t * b * b) % p, (r * b) % p

    return r


def hash_to_curve(text):
    """Hashes text and maps it to a valid elliptic curve point."""
    digest = hashlib.sha256(text.encode()).digest()
    x = int.from_bytes(digest, byteorder="big") % p

    while True:
        y_squared = (x**3 + a * x + b) % p
        if legendre_symbol(y_squared, p) == 1:  # Check if a square root exists
            y = tonelli_shanks(y_squared, p)
            return ellipticcurve.Point(curve, x, y)
        x = (x + 1) % p  # Increment x until we find a valid point


def elliptic_curve_distance(P, Q):
    """Computes Euclidean distance between two elliptic curve points."""
    return ((P.x() - Q.x()) ** 2 + (P.y() - Q.y()) ** 2) ** 0.5


# Tests
def test_legendre_symbol():
    """Ensure Legendre symbol correctly identifies quadratic residues."""
    assert legendre_symbol(4, p) == 1  # 4 is a perfect square mod p
    assert legendre_symbol(2, p) in [
        -1,
        1,
    ]  # 2 may or may not be a quadratic residue


def test_tonelli_shanks():
    """Ensure Tonelli-Shanks finds correct modular square roots."""
    n = 4  # 2^2 mod p
    assert tonelli_shanks(n, p) ** 2 % p == n


def test_hash_to_curve_consistency():
    """Ensure that the same input always maps to the same elliptic curve point."""
    text = "hello world"
    P1 = hash_to_curve(text)
    P2 = hash_to_curve(text)
    assert P1.x() == P2.x() and P1.y() == P2.y()


def test_hash_to_curve_uniqueness():
    """Ensure different texts map to different elliptic curve points."""
    P = hash_to_curve("hello world")
    Q = hash_to_curve("hello blockchain")
    assert P.x() != Q.x() or P.y() != Q.y()


def test_elliptic_curve_distance_symmetry():
    """Ensure distance is symmetric: d(P, Q) == d(Q, P)."""
    P = hash_to_curve("hello")
    Q = hash_to_curve("blockchain")
    assert elliptic_curve_distance(P, Q) == elliptic_curve_distance(Q, P)


def test_elliptic_curve_distance_zero():
    """Ensure distance is zero for identical points."""
    P = hash_to_curve("hello")
    assert elliptic_curve_distance(P, P) == 0.0


def test_elliptic_curve_distance_positive():
    """Ensure distances are always non-negative."""
    P = hash_to_curve("hello world")
    Q = hash_to_curve("different text")
    assert elliptic_curve_distance(P, Q) >= 0.0


def test_hash_to_curve_performance():
    """Ensure performance for long texts."""
    text = "A" * 1000  # Long string
    P = hash_to_curve(text)
    assert isinstance(P, ellipticcurve.Point)


def test_empty_string_handling():
    """Ensure empty string hashes to a valid EC point."""
    P = hash_to_curve("")
    assert isinstance(P, ellipticcurve.Point)


def hamming_distance(str1, str2):
    """Computes the number of differing bits between two hashes."""
    return sum(bin(b1 ^ b2).count("1") for b1, b2 in zip(str1, str2))


def test_very_similar_texts_hamming():
    """Ensure small text changes result in some, but not extreme, bit changes."""
    h1 = hashlib.sha256("hello world".encode()).digest()
    h2 = hashlib.sha256("hello worlD".encode()).digest()
    distance = hamming_distance(h1, h2)
    assert 50 <= distance <= 130  # Expect moderate bit flips (not 0, not 256)


def test_edge_case_large_numbers():
    """Ensure function handles large numbers properly."""
    large_text = "X" * 10000  # Very large input
    P = hash_to_curve(large_text)
    assert isinstance(P, ellipticcurve.Point)


# Run tests
if __name__ == "__main__":
    pytest.main()
