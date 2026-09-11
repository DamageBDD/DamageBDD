# Simple demo of an isogeny function (toy version, not secure!)
# Requires: pip install tinyec

from tinyec import registry

def ecai_isogeny_demo():
    # Step 1: Pick a small elliptic curve over a finite field
    curve = registry.get_curve('secp192r1')
    G = curve.g  # generator point

    print("Curve:", curve.name)
    print("Generator G:", (G.x, G.y))

    # Step 2: Define a kernel point (subgroup generator)
    # For simplicity, we take k*G for a small k
    k = 5
    kernel_point = k * G
    print("Kernel point K:", (kernel_point.x, kernel_point.y))

    # Step 3: Vélu’s formulas (toy)
    # Here we just construct a simple mapping: φ(P) = P + K
    # Real Vélu’s formulas adjust curve coefficients; this is just to illustrate the *mapping idea*.
    def isogeny_map(P):
        return P + kernel_point

    # Step 4: Apply mapping to some points
    P = 7 * G
    Q = 11 * G

    print("\nOriginal P:", (P.x, P.y))
    print("Mapped φ(P):", (isogeny_map(P).x, isogeny_map(P).y))

    print("\nOriginal Q:", (Q.x, Q.y))
    print("Mapped φ(Q):", (isogeny_map(Q).x, isogeny_map(Q).y))

    # Step 5: Determinism check (no guessing!)
    P1 = isogeny_map(P)
    P2 = isogeny_map(P)
    print("\nφ(P) deterministic?", P1 == P2)

if __name__ == "__main__":
    ecai_isogeny_demo()
