"""Classes and functions for creating custom instances of :class:`scipy.sparse.linalg.LinearOperator`."""
import numpy as np
import scipy.sparse.linalg
from builtins import range   # Python 2 compatibility

from . import kronecker

HAVE_MKL = True
try:
    import pyMKL
except:
    HAVE_MKL = False


class NullOperator(scipy.sparse.linalg.LinearOperator):
    """Null operator of the given shape which always returns zeros. Used as placeholder."""
    def __init__(self, shape, dtype=np.float64):
        scipy.sparse.linalg.LinearOperator.__init__(self, shape=shape, dtype=dtype)

    def _matvec(self, x):
        return np.zeros(self.shape[0], dtype=self.dtype)
    def _matmat(self, x):
        return np.zeros((self.shape[0], x.shape[1]), dtype=self.dtype)


def DiagonalOperator(diag):
    """Return a `LinearOperator` which acts like a diagonal matrix
    with the given diagonal."""
    diag = np.squeeze(diag)
    assert diag.ndim == 1, 'Diagonal must be a vector'
    N = diag.shape[0]
    def matvec(x):
        if x.ndim == 1:
            return diag * x
        else:
            return diag[:,None] * x
    return scipy.sparse.linalg.LinearOperator(
        shape=(N,N),
        dtype=diag.dtype,
        matvec=matvec,
        rmatvec=matvec,
        matmat=matvec
    )


def KroneckerOperator(*ops):
    """Return a `LinearOperator` which efficiently implements the
    application of the Kronecker product of the given input operators.
    """
    # assumption: all operators are square
    sz = np.prod([A.shape[0] for A in ops])
    if all(isinstance(A, np.ndarray) for A in ops):
        applyfunc = lambda x: kronecker._apply_kronecker_dense(ops, x)
        return scipy.sparse.linalg.LinearOperator(shape=(sz,sz),
                matvec=applyfunc, matmat=applyfunc)
    else:
        ops = [scipy.sparse.linalg.aslinearoperator(B) for B in ops]
        applyfunc = lambda x: kronecker._apply_kronecker_linops(ops, x)
        return scipy.sparse.linalg.LinearOperator(shape=(sz,sz),
                matvec=applyfunc, matmat=applyfunc)


class BaseBlockOperator(scipy.sparse.linalg.LinearOperator):
    def __init__(self, shape, ops, ran_out, ran_in):
        self.ops = ops
        self.ran_out = ran_out
        self.ran_in = ran_in
        scipy.sparse.linalg.LinearOperator.__init__(self, ops[0].dtype, shape)
    
    def _matvec(self, x):
        y = np.zeros(self.shape[0])
        if x.ndim == 2:
            x = x[:,0]
        for i in range(len(self.ops)):
            y[self.ran_out[i]] += self.ops[i].dot(x[self.ran_in[i]])
        return y

    def _matmat(self, x):
        y = np.zeros((self.shape[0], x.shape[1]))
        for i in range(len(self.ops)):
            y[self.ran_out[i]] += self.ops[i].dot(x[self.ran_in[i]])
        return y


def _sizes_to_ranges(sizes):
    """Convert an iterable of sizes into a list of consecutive ranges of these sizes."""
    sizes = list(sizes)
    runsizes = [0] + list(np.cumsum(sizes))
    return [range(runsizes[k], runsizes[k+1]) for k in range(len(sizes))]


def BlockDiagonalOperator(*ops):
    """Return a `LinearOperator` with block diagonal structure, with the given
    operators on the diagonal.
    """
    K = len(ops)
    ranges_i = _sizes_to_ranges(op.shape[0] for op in ops)
    ranges_j = _sizes_to_ranges(op.shape[1] for op in ops)
    shape = (ranges_i[-1].stop, ranges_j[-1].stop)
    return BaseBlockOperator(shape, ops, ranges_i, ranges_j)


def BlockOperator(ops):
    M, N = len(ops), len(ops[0])
    ranges_i = _sizes_to_ranges(ops[i][0].shape[0] for i in range(M))
    ranges_j = _sizes_to_ranges(ops[0][j].shape[1] for j in range(N))
    shape = (ranges_i[-1].stop, ranges_j[-1].stop)

    ops_list, ranges_i_list, ranges_j_list = [], [], []
    for i in range(M):
        assert len(ops[i]) == N, "All rows must have equal length"
        for j in range(N):
            op = ops[i][j]
            if op is None or isinstance(op, NullOperator):
                continue
            else:
                assert op.shape == (len(ranges_i[i]), len(ranges_j[j]))
                ops_list.append(op)
                ranges_i_list.append(ranges_i[i])
                ranges_j_list.append(ranges_j[j])
    if ops_list:
        return BaseBlockOperator(shape, ops_list, ranges_i_list, ranges_j_list)
    else:
        return NullOperator(shape)


def make_solver(B, symmetric=False):
    """Return a `LinearOperator` that acts as a linear solver for the (dense or sparse) square matrix B.
    
    If `B` is symmetric, passing ``symmetric=True`` may try to take advantage of this."""
    if scipy.sparse.issparse(B):
        if HAVE_MKL:
            # use MKL Pardiso
            solver = pyMKL.pardisoSolver(B, -2 if symmetric else 11)
            solver.factor()
            return scipy.sparse.linalg.LinearOperator(B.shape, dtype=B.dtype,
                    matvec=solver.solve, matmat=solver.solve)
        else:
            # use SuperLU (unless scipy uses UMFPACK?) -- really slow!
            spLU = scipy.sparse.linalg.splu(B.tocsc(), permc_spec='NATURAL')
            return scipy.sparse.linalg.LinearOperator(B.shape, dtype=B.dtype,
                    matvec=spLU.solve, matmat=spLU.solve)
    else:
        if symmetric:
            chol = scipy.linalg.cho_factor(B, check_finite=False)
            solve = lambda x: scipy.linalg.cho_solve(chol, x, check_finite=False)
            return scipy.sparse.linalg.LinearOperator(B.shape, dtype=B.dtype,
                    matvec=solve, matmat=solve)
        else:
            LU = scipy.linalg.lu_factor(B, check_finite=False)
            solve = lambda x: scipy.linalg.lu_solve(LU, x, check_finite=False)
            return scipy.sparse.linalg.LinearOperator(B.shape, dtype=B.dtype,
                    matvec=solve, matmat=solve)


def make_kronecker_solver(*Bs): #, symmetric=False): # kw arg doesn't work in Py2
    """Given several square matrices, return an operator which efficiently applies
    the inverse of their Kronecker product.
    """
    Binvs = tuple(make_solver(B) for B in Bs)
    return KroneckerOperator(*Binvs)

