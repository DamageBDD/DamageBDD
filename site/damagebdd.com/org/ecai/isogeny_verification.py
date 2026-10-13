# Elliptic-curve isogeny demo (finite field, no continuity involved)
# We use the multiplication-by-m map φ = [m], which is itself an isogeny (degree m^2).
# Verifies φ(P+Q) = φ(P) + φ(Q) on random samples over a small curve mod p.

from dataclasses import dataclass
from typing import Optional, List
import random

# Finite field prime and short-Weierstrass curve
p = 101
a = 2
b = 3

@dataclass(frozen=True)
class ECPoint:
    x: Optional[int]
    y: Optional[int]
    infinity: bool = False

O = ECPoint(None, None, True)

def inv_mod(x: int, p: int) -> int:
    return pow(x, p-2, p)

def is_on_curve(P: ECPoint) -> bool:
    if P.infinity:
        return True
    x, y = P.x % p, P.y % p
    return (y*y - (x*x*x + a*x + b)) % p == 0

def ec_add(P: ECPoint, Q: ECPoint) -> ECPoint:
    if P.infinity: return Q
    if Q.infinity: return P
    if P.x == Q.x and (P.y != Q.y or P.y == 0):
        return O
    if P.x == Q.x and P.y == Q.y:
        s = (3*P.x*P.x + a) * inv_mod((2*P.y) % p, p) % p
    else:
        s = ((Q.y - P.y) % p) * inv_mod((Q.x - P.x) % p, p) % p
    x_r = (s*s - P.x - Q.x) % p
    y_r = (s*(P.x - x_r) - P.y) % p
    return ECPoint(x_r, y_r)

def ec_mul(k: int, P: ECPoint) -> ECPoint:
    R = O
    Q = P
    while k > 0:
        if k & 1: R = ec_add(R, Q)
        Q = ec_add(Q, Q)
        k >>= 1
    return R

def enumerate_points(limit=200) -> List[ECPoint]:
    pts = []
    for x in range(p):
        rhs = (x**3 + a*x + b) % p
        for y in range(p):
            if (y*y) % p == rhs:
                P = ECPoint(x, y)
                if is_on_curve(P):
                    pts.append(P)
                    if len(pts) >= limit:
                        return pts
    return pts

# Build a pool of points
points = enumerate_points(120)

# Define the isogeny φ = [m] (choose m=3; degree 9)
m = 3
def phi(P: ECPoint) -> ECPoint:
    return ec_mul(m, P)

# Verify homomorphism: φ(P+Q) == φ(P) + φ(Q)
def homomorphism_check(trials=12):
    ok = 0
    for _ in range(trials):
        A, B = random.sample(points, 2)
        lhs = phi(ec_add(A, B))
        rhs = ec_add(phi(A), phi(B))
        if lhs == rhs:
            ok += 1
    return ok, trials

if __name__ == "__main__":
    ok, trials = homomorphism_check()
    print(f"Field prime p = {p}")
    print(f"Curve E: y^2 = x^3 + {a}x + {b} (mod {p})")
    print(f"Isogeny φ = [{m}] (degree = {m*m})")
    print(f"Homomorphism check: {ok}/{trials} random cases satisfied\n")

    # Show some example mappings
    for P in points[:5]:
        Im = phi(P)
        print(f"P=({P.x},{P.y})  ->  φ(P)=({Im.x},{Im.y})")
