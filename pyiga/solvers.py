"""Linear solvers."""
import numpy as np
import numpy.linalg
import scipy.linalg
from .operators import make_solver, KroneckerOperator, DiagonalOperator

from functools import reduce


def _asdense(X):
    try:
        return X.A
    except:
        return X


def fastdiag_solver(KM):
    """The fast diagonalization solver as described in [Sangalli, Tani 2016].

    Args:
        KM: a sequence of length `d` (dimension of the problem) containing pairs
            of symmetric matrices `(K_i, M_i)`

    Returns:
        A `LinearOperator` which realizes the inverse of the generalized Laplacian
        matrix described by the input matrices.
    """
    dim = len(KM)
    n = tuple(K.shape[0] for (K,_) in KM)
    EV = [scipy.linalg.eigh(_asdense(K), _asdense(M)) for (K,M) in KM]

    diags = []
    for d in range(dim):
        D = [np.ones(n[j]) for j in range(dim)]
        D[d] = EV[d][0]  # eigenvalues
        diags.append(reduce(np.kron, D))
    diag = sum(diags)

    l_op = KroneckerOperator(*tuple(U   for (_,U) in EV))
    r_op = KroneckerOperator(*tuple(U.T for (_,U) in EV))

    return l_op * DiagonalOperator(1.0 / diag) * r_op


## Smoothers

def OperatorSmoother(S):
    """A smoother which applies an arbitrary operator `S` to the residual
    and uses the result as an update, i.e.,

    .. math::
        u \leftarrow u + S(f - Au).
    """
    def apply(A, u, f):
        u += S.dot(f - A.dot(u))
    return apply

def GaussSeidelSmoother(iterations=1, sweep='forward'):
    """Gauss-Seidel smoother.

    By default, `iterations` is 1. The direction to be used is specified by
    `sweep` and may be either 'forward', 'backward', or 'symmetric'."""
    from .relaxation import gauss_seidel
    def apply(A, u, f):
        gauss_seidel(A, u, f, iterations=iterations, sweep=sweep)
    return apply

def SequentialSmoother(smoothers):
    """Smoother which applies several smoothers in sequence."""
    def apply(A, u, f):
        for S in smoothers:
            S(A, u, f)
    return apply


## Multigrid

def twogrid(A, f, P, smoother, u0=None, tol=1e-8, smooth_steps=2, maxiter=1000):
    """Generic two-grid method with arbitrary smoother.

    Args:
        A: stiffness matrix on fine grid
        f: right-hand side
        P: prolongation matrix from coarse to fine grid
        smoother: a function with arguments `(A,u,f)` which applies one smoothing iteration in-place to `u`
        u0: starting value; 0 if not given
        tol: desired reduction relative to initial residual
        smooth_steps: number of smoothing steps
        maxiter: maximum number of iterations

    Returns:
        ndarray: the computed solution to the equation `Au = f`
    """
    A_c = (P.T.dot(A).dot(P)) #.A
    A_c_inv = make_solver(A_c)

    u = np.array(u0) if u0 else np.zeros(A.shape[0])
    res0 = np.linalg.norm(f - A.dot(u))
    numiter = 0

    while True:
        for _ in range(smooth_steps):
            smoother(A, u, f)

        # coarse-grid correction
        r = f - A.dot(u)
        res = np.linalg.norm(r)
        u += P.dot(A_c_inv * P.T.dot(r))

        numiter += 1

        if res < tol * res0:
            break
        elif res > 20 * res0:
            print('Diverged')
            break
        elif numiter > maxiter:
            print('too many iterations, aborting. reduction =', res/res0)
            break
    print(numiter, 'iterations')
    return u
