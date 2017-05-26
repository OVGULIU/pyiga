# cython: language_level=3
# cython: profile=False
# cython: linetrace=False
# cython: binding=False

from builtins import range as range_it   # Python 2 compatibility

cimport cython
from cython.parallel import prange
from libcpp.vector cimport vector

import numpy as np
cimport numpy as np

import scipy.sparse

import pyiga
from . import bspline
from .quadrature import make_iterated_quadrature
from . cimport fast_assemble_cy

from concurrent.futures import ThreadPoolExecutor
import multiprocessing

import itertools

################################################################################
# Public utility functions
################################################################################

cpdef void rank_1_update(double[:,::1] X, double alpha, double[::1] u, double[::1] v):
    """Perform the update `X += alpha * u * v^T`.

    This does the same thing as the BLAS function `dger`, but OpenBLAS
    tries to parallelize it, which hurts more than it helps. Instead of
    forcing OMP_NUM_THREADS=1, which slows down many other things,
    we write our own.
    """
    cdef double au
    cdef size_t i, j
    for i in range(X.shape[0]):
        au = alpha * u[i]
        for j in range(X.shape[1]):
            X[i,j] += au * v[j]

cpdef void aca3d_update(double[:,:,::1] X, double alpha, double[::1] u, double[:,::1] V):
    cdef double au
    cdef size_t i, j, k
    for i in range(X.shape[0]):
        au = alpha * u[i]
        for j in range(X.shape[1]):
            for k in range(X.shape[2]):
                X[i,j,k] += au * V[j,k]

cdef inline void from_seq3(size_t i, size_t[3] ndofs, size_t[3] out) nogil:
    out[2] = i % ndofs[2]
    i /= ndofs[2]
    out[1] = i % ndofs[1]
    i /= ndofs[1]
    out[0] = i

# returns an array where each row contains:
#  i0 i1 i2  j0 j1 j2  t0 t1 t2
# where ix and jx are block indices of a matrix entry
# and (t0,t1,t2) is a single tile index which is contained
# in the joint support for the matrix entry
def prepare_tile_indices3(ij_arr, meshsupp, numdofs):
    cdef size_t[3] ndofs
    ndofs[:] = numdofs
    cdef vector[unsigned] result
    cdef size_t I[3]
    cdef size_t J[3]
    cdef size_t[:, :] ij = ij_arr
    cdef size_t N = ij.shape[0], M = 0
    cdef IntInterval[3] intvs

    for k in range(N):
        from_seq3(ij[k,0], ndofs, I)
        from_seq3(ij[k,1], ndofs, J)

        for r in range(3):
            ii = I[r]
            jj = J[r]
            intvs[r] = intersect_intervals(
                make_intv(meshsupp[r][ii, 0], meshsupp[r][ii, 1]),
                make_intv(meshsupp[r][jj, 0], meshsupp[r][jj, 1]))

        for t0 in range(intvs[0].a, intvs[0].b):
            for t1 in range(intvs[1].a, intvs[1].b):
                for t2 in range(intvs[2].a, intvs[2].b):
                    result.push_back(I[0])
                    result.push_back(I[1])
                    result.push_back(I[2])
                    result.push_back(J[0])
                    result.push_back(J[1])
                    result.push_back(J[2])
                    result.push_back(t0)
                    result.push_back(t1)
                    result.push_back(t2)
                    M += 1
    return np.array(<unsigned[:result.size()]> result.data(), order='C').reshape((M,9))


# Used to recombine the results of tile-wise assemblers, where a single matrix
# entry is split up into is contributions per tile. This class sums these
# contributions up again.
cdef class MatrixEntryAccumulator:
    cdef ssize_t idx
    cdef int num_indices
    cdef double[::1] _result
    cdef unsigned[16] old_indices

    def __init__(self, int num_indices, size_t N):
        self.idx = -1
        assert num_indices <= 16
        self.num_indices = num_indices
        self._result = np.empty(N)
        for i in range(16):
            self.old_indices[i] = 0xffffffff

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef bint index_changed(self, unsigned[:, :] indices, size_t i) nogil:
        cdef bint changed = False
        for k in range(self.num_indices):
            if indices[i, k] != self.old_indices[k]:
                changed = True
                break
        if changed: # update old_indices
            for k in range(self.num_indices):
                self.old_indices[k] = indices[i, k]
        return changed

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cpdef process(self, unsigned[:, :] indices, double[::1] values):
        cdef size_t M = indices.shape[0]
        for i in range(M):
            if self.index_changed(indices, i):
                self.idx += 1
                self._result[self.idx] = values[i]
            else:
                self._result[self.idx] += values[i]

    @property
    def result(self):
        return self._result[:self.idx+1]


################################################################################
# Internal helper functions
################################################################################

cdef struct IntInterval:
    int a
    int b

cdef IntInterval make_intv(int a, int b) nogil:
    cdef IntInterval intv
    intv.a = a
    intv.b = b
    return intv

cdef IntInterval intersect_intervals(IntInterval intva, IntInterval intvb) nogil:
    return make_intv(max(intva.a, intvb.a), min(intva.b, intvb.b))


cdef int next_lexicographic2(size_t[2] cur, size_t start[2], size_t end[2]) nogil:
    cdef size_t i
    for i in range(2):
        cur[i] += 1
        if cur[i] == end[i]:
            if i == (2-1):
                return 0
            else:
                cur[i] = start[i]
        else:
            return 1

cdef int next_lexicographic3(size_t[3] cur, size_t start[3], size_t end[3]) nogil:
    cdef size_t i
    for i in range(3):
        cur[i] += 1
        if cur[i] == end[i]:
            if i == (3-1):
                return 0
            else:
                cur[i] = start[i]
        else:
            return 1

@cython.boundscheck(False)
@cython.wraparound(False)
cdef IntInterval find_joint_support_functions(ssize_t[:,::1] meshsupp, long i) nogil:
    cdef long j, n, minj, maxj
    minj = j = i
    while j >= 0 and meshsupp[j,1] > meshsupp[i,0]:
        minj = j
        j -= 1

    maxj = i
    j = i + 1
    n = meshsupp.shape[0]
    while j < n and meshsupp[j,0] < meshsupp[i,1]:
        maxj = j
        j += 1
    return make_intv(minj, maxj+1)
    #return IntInterval(minj, maxj+1)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void outer_prod(double[::1] x1, double[::1] x2, double[:,:] out) nogil:
    cdef size_t n1 = x1.shape[0], n2 = x2.shape[0]
    cdef size_t i, j

    for i in range(n1):
        for j in range(n2):
            out[i,j] = x1[i] * x2[j]

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void outer_prod3(double[::1] x1, double[::1] x2, double[::1] x3, double[:,:,:] out) nogil:
    cdef size_t n1 = x1.shape[0], n2 = x2.shape[0], n3 = x3.shape[0]
    cdef size_t i, j, k

    for i in range(n1):
        for j in range(n2):
            for k in range(n3):
                out[i,j,k] = x1[i] * x2[j] * x3[k]


#### determinants and inverses

def det_and_inv(X):
    """Return (np.linalg.det(X), np.linalg.inv(X)), but much
    faster for 2x2- and 3x3-matrices."""
    d = X.shape[-1]
    if d == 2:
        det = np.empty(X.shape[:-2])
        inv = det_and_inv_2x2(X, det)
        return det, inv
    elif d == 3:
        det = np.empty(X.shape[:-2])
        inv = det_and_inv_3x3(X, det)
        return det, inv
    else:
        return np.linalg.det(X), np.linalg.inv(X)

def determinants(X):
    """Compute the determinants of an ndarray of square matrices.

    This behaves mostly identically to np.linalg.det(), but is faster for 2x2 matrices."""
    shape = X.shape
    d = shape[-1]
    assert shape[-2] == d, "Input matrices need to be square"
    if d == 2:
        # optimization for 2x2 matrices
        assert len(shape) == 4, "Only implemented for n x m x 2 x 2 arrays"
        return X[:,:,0,0] * X[:,:,1,1] - X[:,:,0,1] * X[:,:,1,0]
    elif d == 3:
        return determinants_3x3(X)
    else:
        return np.linalg.det(X)

def inverses(X):
    if X.shape[-2:] == (2,2):
        return inverses_2x2(X)
    elif X.shape[-2:] == (3,3):
        return inverses_3x3(X)
    else:
        return np.linalg.inv(X)

#### 2D determinants and inverses

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef double[:,:,:,::1] det_and_inv_2x2(double[:,:,:,::1] X, double[:,::1] det_out):
    cdef long m,n, i,j
    cdef double det, a,b,c,d
    m,n = X.shape[0], X.shape[1]

    cdef double[:,:,:,::1] Y = np.empty_like(X)
    for i in prange(m, nogil=True, schedule='static'):
        for j in range(n):
            a,b,c,d = X[i,j, 0,0], X[i,j, 0,1], X[i,j, 1,0], X[i,j, 1,1]
            det = a*d - b*c
            det_out[i,j] = det
            Y[i,j, 0,0] =  d / det
            Y[i,j, 0,1] = -b / det
            Y[i,j, 1,0] = -c / det
            Y[i,j, 1,1] =  a / det
    return Y

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef double[:,:,:,::1] inverses_2x2(double[:,:,:,::1] X):
    cdef size_t m,n, i,j
    cdef double det, a,b,c,d
    m,n = X.shape[0], X.shape[1]

    cdef double[:,:,:,::1] Y = np.empty_like(X)
    for i in range(m):
        for j in range(n):
            a,b,c,d = X[i,j, 0,0], X[i,j, 0,1], X[i,j, 1,0], X[i,j, 1,1]
            det = a*d - b*c
            Y[i,j, 0,0] =  d / det
            Y[i,j, 0,1] = -b / det
            Y[i,j, 1,0] = -c / det
            Y[i,j, 1,1] =  a / det
    return Y

#### 3D determinants and inverses

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef double[:,:,:,:,::1] det_and_inv_3x3(double[:,:,:,:,::1] X, double[:,:,::1] det_out):
    cdef long n0, n1, n2, i0, i1, i2
    cdef double det, invdet
    n0,n1,n2 = X.shape[0], X.shape[1], X.shape[2]
    cdef double x00,x01,x02,x10,x11,x12,x20,x21,x22

    cdef double[:,:,:,:,::1] Y = np.empty_like(X)

    for i0 in prange(n0, nogil=True, schedule='static'):
        for i1 in range(n1):
            for i2 in range(n2):
                x00,x01,x02 = X[i0, i1, i2, 0, 0], X[i0, i1, i2, 0, 1], X[i0, i1, i2, 0, 2]
                x10,x11,x12 = X[i0, i1, i2, 1, 0], X[i0, i1, i2, 1, 1], X[i0, i1, i2, 1, 2]
                x20,x21,x22 = X[i0, i1, i2, 2, 0], X[i0, i1, i2, 2, 1], X[i0, i1, i2, 2, 2]

                det = x00 * (x11 * x22 - x21 * x12) - \
                      x01 * (x10 * x22 - x12 * x20) + \
                      x02 * (x10 * x21 - x11 * x20)

                det_out[i0, i1, i2] = det

                invdet = 1.0 / det

                Y[i0, i1, i2, 0, 0] = (x11 * x22 - x21 * x12) * invdet
                Y[i0, i1, i2, 0, 1] = (x02 * x21 - x01 * x22) * invdet
                Y[i0, i1, i2, 0, 2] = (x01 * x12 - x02 * x11) * invdet
                Y[i0, i1, i2, 1, 0] = (x12 * x20 - x10 * x22) * invdet
                Y[i0, i1, i2, 1, 1] = (x00 * x22 - x02 * x20) * invdet
                Y[i0, i1, i2, 1, 2] = (x10 * x02 - x00 * x12) * invdet
                Y[i0, i1, i2, 2, 0] = (x10 * x21 - x20 * x11) * invdet
                Y[i0, i1, i2, 2, 1] = (x20 * x01 - x00 * x21) * invdet
                Y[i0, i1, i2, 2, 2] = (x00 * x11 - x10 * x01) * invdet

    return Y

@cython.boundscheck(False)
@cython.wraparound(False)
cdef double[:,:,::1] determinants_3x3(double[:,:,:,:,::1] X):
    cdef size_t n0, n1, n2, i0, i1, i2
    n0,n1,n2 = X.shape[0], X.shape[1], X.shape[2]

    cdef double[:,:,::1] Y = np.empty((n0,n1,n2))
    cdef double[:,::1] x

    for i0 in range(n0):
        for i1 in range(n1):
            for i2 in range(n2):
                x = X[i0, i1, i2, :, :]

                Y[i0,i1,i2] = x[0, 0] * (x[1, 1] * x[2, 2] - x[2, 1] * x[1, 2]) - \
                              x[0, 1] * (x[1, 0] * x[2, 2] - x[1, 2] * x[2, 0]) + \
                              x[0, 2] * (x[1, 0] * x[2, 1] - x[1, 1] * x[2, 0])
    return Y

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef double[:,:,:,:,::1] inverses_3x3(double[:,:,:,:,::1] X):
    cdef size_t n0, n1, n2, i0, i1, i2
    cdef double det, invdet
    n0,n1,n2 = X.shape[0], X.shape[1], X.shape[2]

    cdef double[:,:,:,:,::1] Y = np.empty_like(X)
    cdef double[:,::1] x, y

    for i0 in range(n0):
        for i1 in range(n1):
            for i2 in range(n2):
                x = X[i0, i1, i2, :, :]
                y = Y[i0, i1, i2, :, :]

                det = x[0, 0] * (x[1, 1] * x[2, 2] - x[2, 1] * x[1, 2]) - \
                      x[0, 1] * (x[1, 0] * x[2, 2] - x[1, 2] * x[2, 0]) + \
                      x[0, 2] * (x[1, 0] * x[2, 1] - x[1, 1] * x[2, 0])

                invdet = 1.0 / det

                y[0, 0] = (x[1, 1] * x[2, 2] - x[2, 1] * x[1, 2]) * invdet
                y[0, 1] = (x[0, 2] * x[2, 1] - x[0, 1] * x[2, 2]) * invdet
                y[0, 2] = (x[0, 1] * x[1, 2] - x[0, 2] * x[1, 1]) * invdet
                y[1, 0] = (x[1, 2] * x[2, 0] - x[1, 0] * x[2, 2]) * invdet
                y[1, 1] = (x[0, 0] * x[2, 2] - x[0, 2] * x[2, 0]) * invdet
                y[1, 2] = (x[1, 0] * x[0, 2] - x[0, 0] * x[1, 2]) * invdet
                y[2, 0] = (x[1, 0] * x[2, 1] - x[2, 0] * x[1, 1]) * invdet
                y[2, 1] = (x[2, 0] * x[0, 1] - x[0, 0] * x[2, 1]) * invdet
                y[2, 2] = (x[0, 0] * x[1, 1] - x[1, 0] * x[0, 1]) * invdet

    return Y


cpdef double[:,:,:,::1] matmatT_2x2(double[:,:,:,::1] B):
    """Compute B * B^T for each matrix in the input."""
    cdef double[:,:,:,::1] X = np.zeros_like(B, order='C')
    cdef size_t n0 = B.shape[0]
    cdef size_t n1 = B.shape[1]
    for i0 in range(n0):
        for i1 in range(n1):
            for j in range(2):
                for k in range(2):
                    for l in range(2):
                        X[i0,i1, j,l] += B[i0,i1, j,k] * B[i0,i1, l,k]
    return X

cpdef double[:,:,:,:,::1] matmatT_3x3(double[:,:,:,:,::1] B):
    """Compute B * B^T for each matrix in the input."""
    cdef double[:,:,:,:,::1] X = np.zeros_like(B, order='C')
    cdef size_t n0 = B.shape[0]
    cdef size_t n1 = B.shape[1]
    cdef size_t n2 = B.shape[2]
    for i0 in range(n0):
        for i1 in range(n1):
            for i2 in range(n2):
                for j in range(3):
                    for k in range(3):
                        for l in range(3):
                            X[i0,i1,i2, j,l] += B[i0,i1,i2, j,k] * B[i0,i1,i2, l,k]
    return X


#### Parallelization

def chunk_tasks(tasks, num_chunks):
    """Generator that splits the list `tasks` into roughly `num_chunks` equally-sized parts."""
    n = len(tasks) // num_chunks + 1
    for i in range(0, len(tasks), n):
        yield tasks[i:i+n]

cdef object _threadpool = None

cdef object get_thread_pool():
    global _threadpool
    if _threadpool is None:
        _threadpool = ThreadPoolExecutor(pyiga.get_max_threads())
    return _threadpool

################################################################################
# Assembler kernels
################################################################################

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.initializedcheck(False)
cdef double combine_mass_2d(
        double[:,::1] J,
        double* Vu0, double* Vu1,
        double* Vv0, double* Vv1
    ) nogil:
    """Compute the sum of J*u*v over a 2D grid."""
    cdef size_t n0 = J.shape[0]
    cdef size_t n1 = J.shape[1]

    cdef size_t i0, i1
    cdef double result = 0.0

    for i0 in range(n0):
        for i1 in range(n1):
            result += Vu0[i0]*Vu1[i1] * Vv0[i0]*Vv1[i1] * J[i0,i1]
    return result


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.initializedcheck(False)
cdef double combine_stiff_2d(
        double[:,:,:,::1] B,
        double* VDu0, double* VDu1,
        double* VDv0, double* VDv1,
    ) nogil:
    """Compute the sum of (B grad(u), grad(v)) over a 2D grid."""
    cdef size_t n0 = B.shape[0]
    cdef size_t n1 = B.shape[1]

    cdef double result = 0.0
    cdef size_t i0, i1
    cdef double gu[2]
    cdef double gv[2]
    cdef double *Bptr

    for i0 in range(n0):
        for i1 in range(n1):
            Bptr = &B[i0, i1, 0, 0]

            gu[0] = VDu0[2*i0]   * VDu1[2*i1+1]
            gu[1] = VDu0[2*i0+1] * VDu1[2*i1]

            gv[0] = VDv0[2*i0]   * VDv1[2*i1+1]
            gv[1] = VDv0[2*i0+1] * VDv1[2*i1]

            result += (Bptr[0]*gu[0] + Bptr[1]*gu[1]) * gv[0]
            result += (Bptr[2]*gu[0] + Bptr[3]*gu[1]) * gv[1]
    return result


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.initializedcheck(False)
cdef double combine_mass_3d(
        double[:,:,::1] J,
        double* Vu0, double* Vu1, double* Vu2,
        double* Vv0, double* Vv1, double* Vv2
    ) nogil:
    """Compute the sum of J*u*v over a 2D grid."""
    cdef size_t n0 = J.shape[0]
    cdef size_t n1 = J.shape[1]
    cdef size_t n2 = J.shape[2]

    cdef size_t i0, i1, i2
    cdef double result = 0.0

    for i0 in range(n0):
        for i1 in range(n1):
            for i2 in range(n2):
                result += Vu0[i0]*Vu1[i1]*Vu2[i2] * Vv0[i0]*Vv1[i1]*Vv2[i2] * J[i0,i1,i2]

    return result

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.initializedcheck(False)
cdef double combine_stiff_3d(
        double[:,:,:,:,::1] B,
        double* VDu0, double* VDu1, double* VDu2,
        double* VDv0, double* VDv1, double* VDv2,
    ) nogil:
    """Compute the sum of (B grad(u), grad(v)) over a 3D grid"""
    cdef size_t n0 = B.shape[0]
    cdef size_t n1 = B.shape[1]
    cdef size_t n2 = B.shape[2]

    cdef double result = 0.0
    cdef size_t i0, i1, i2
    cdef double gu[3]
    cdef double gv[3]
    cdef double *Bptr

    for i0 in range(n0):
        for i1 in range(n1):
            for i2 in range(n2):
                Bptr = &B[i0, i1, i2, 0, 0]

                gu[0] = VDu0[2*i0]   * VDu1[2*i1]   * VDu2[2*i2+1]
                gu[1] = VDu0[2*i0]   * VDu1[2*i1+1] * VDu2[2*i2]
                gu[2] = VDu0[2*i0+1] * VDu1[2*i1]   * VDu2[2*i2]

                gv[0] = VDv0[2*i0]   * VDv1[2*i1]   * VDv2[2*i2+1]
                gv[1] = VDv0[2*i0]   * VDv1[2*i1+1] * VDv2[2*i2]
                gv[2] = VDv0[2*i0+1] * VDv1[2*i1]   * VDv2[2*i2]

                result += (Bptr[0]*gu[0] + Bptr[1]*gu[1] + Bptr[2]*gu[2]) * gv[0]
                result += (Bptr[3]*gu[0] + Bptr[4]*gu[1] + Bptr[5]*gu[2]) * gv[1]
                result += (Bptr[6]*gu[0] + Bptr[7]*gu[1] + Bptr[8]*gu[2]) * gv[2]
    return result



################################################################################
# 2D Assemblers
################################################################################

cdef class BaseAssembler2D:
    cdef int nqp
    cdef size_t[2] ndofs
    cdef vector[ssize_t[:,::1]] meshsupp
    cdef list _asm_pool     # list of shared clones for multithreading

    cdef void base_init(self, kvs):
        assert len(kvs) == 2, "Assembler requires two knot vectors"
        self.nqp = max([kv.p for kv in kvs]) + 1
        self.ndofs[:] = [kv.numdofs for kv in kvs]
        self.meshsupp = [kvs[k].mesh_support_idx_all() for k in range(2)]
        self._asm_pool = []

    cdef _share_base(self, BaseAssembler2D asm):
        asm.nqp = self.nqp
        asm.ndofs[:] = self.ndofs[:]
        asm.meshsupp = self.meshsupp

    cdef BaseAssembler2D shared_clone(self):
        return None     # not implemented

    cdef inline size_t to_seq(self, size_t[2] ii) nogil:
        # by convention, the order of indices is (y,x)
        return ii[0] * self.ndofs[1] + ii[1]

    @cython.cdivision(True)
    cdef inline void from_seq(self, size_t i, size_t[2] out) nogil:
        out[0] = i / self.ndofs[1]
        out[1] = i % self.ndofs[1]

    cdef double assemble_impl(self, size_t[2] i, size_t[2] j) nogil:
        return -9999.99  # Not implemented

    cpdef double assemble(self, size_t i, size_t j):
        cdef size_t[2] I, J
        with nogil:
            self.from_seq(i, I)
            self.from_seq(j, J)
            return self.assemble_impl(I, J)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void multi_assemble_chunk(self, size_t[:,::1] idx_arr, double[::1] out) nogil:
        cdef size_t[2] I, J
        cdef size_t k

        for k in range(idx_arr.shape[0]):
            self.from_seq(idx_arr[k,0], I)
            self.from_seq(idx_arr[k,1], J)
            out[k] = self.assemble_impl(I, J)

    def multi_assemble(self, indices):
        cdef size_t[:,::1] idx_arr = np.array(list(indices), dtype=np.uintp)
        cdef double[::1] result = np.empty(idx_arr.shape[0])

        num_threads = pyiga.get_max_threads()
        if num_threads <= 1:
            self.multi_assemble_chunk(idx_arr, result)
        else:
            thread_pool = get_thread_pool()
            if not self._asm_pool:
                self._asm_pool = [self] + [self.shared_clone()
                        for i in range(1, thread_pool._max_workers)]

            results = thread_pool.map(_asm_chunk_2d,
                        self._asm_pool,
                        chunk_tasks(idx_arr, num_threads),
                        chunk_tasks(result, num_threads))
            list(results)   # wait for threads to finish
        return result

cpdef void _asm_chunk_2d(BaseAssembler2D asm, size_t[:,::1] idxchunk, double[::1] out):
    with nogil:
        asm.multi_assemble_chunk(idxchunk, out)


cdef class MassAssembler2D(BaseAssembler2D):
    # shared data
    cdef vector[double[::1,:]] C
    cdef double[:,::1] geo_weights

    def __init__(self, kvs, geo):
        assert geo.dim == 2, "Geometry has wrong dimension"
        self.base_init(kvs)

        gauss = [make_iterated_quadrature(np.unique(kv.kv), self.nqp) for kv in kvs]
        gaussgrid = [g[0] for g in gauss]
        gaussweights = [g[1] for g in gauss]
        self.C  = [bspline.collocation(kvs[k], gaussgrid[k])
                   .toarray(order='F') for k in range(2)]

        geo_jac    = geo.grid_jacobian(gaussgrid)
        geo_det    = np.abs(determinants(geo_jac))
        self.geo_weights = gaussweights[0][:,None] * gaussweights[1][None,:] * geo_det

    cdef MassAssembler2D shared_clone(self):
        return self     # no shared data; class is thread-safe

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    cdef double assemble_impl(self, size_t[2] i, size_t[2] j) nogil:
        cdef int k
        cdef IntInterval intv
        cdef size_t g_sta[2]
        cdef size_t g_end[2]

        cdef (double*) values_i[2]
        cdef (double*) values_j[2]

        for k in range(2):
            intv = intersect_intervals(make_intv(self.meshsupp[k][i[k],0], self.meshsupp[k][i[k],1]),
                                       make_intv(self.meshsupp[k][j[k],0], self.meshsupp[k][j[k],1]))
            if intv.a >= intv.b:
                return 0.0      # no intersection of support
            g_sta[k] = self.nqp * intv.a    # start of Gauss nodes
            g_end[k] = self.nqp * intv.b    # end of Gauss nodes

            values_i[k] = &self.C[k][ g_sta[k], i[k] ]
            values_j[k] = &self.C[k][ g_sta[k], j[k] ]

        return combine_mass_2d(
            self.geo_weights[ g_sta[0]:g_end[0], g_sta[1]:g_end[1] ],
            values_i[0], values_i[1],
            values_j[0], values_j[1]
        )


cdef class StiffnessAssembler2D(BaseAssembler2D):
    # shared data
    cdef vector[double[:, :, ::1]] C    # basis values. Indices: basis function, mesh point, derivative
    cdef double[:, :, :, ::1] B         # transformation matrix. Indices: 2 x mesh point, i, j

    def __init__(self, kvs, geo):
        assert geo.dim == 2, "Geometry has wrong dimension"
        self.base_init(kvs)

        gauss = [make_iterated_quadrature(np.unique(kv.kv), self.nqp) for kv in kvs]
        gaussgrid = [g[0] for g in gauss]
        gaussweights = [g[1] for g in gauss]
        colloc = [bspline.collocation_derivs(kvs[k], gaussgrid[k], derivs=1) for k in range(2)]
        self.C = [np.stack((X.T.A, Y.T.A), axis=-1) for (X,Y) in colloc]

        geo_jac = geo.grid_jacobian(gaussgrid)
        geo_det, geo_jacinv = det_and_inv(geo_jac)
        weights = gaussweights[0][:,None] * gaussweights[1][None,:] * np.abs(geo_det)
        self.B = matmatT_2x2(geo_jacinv) * weights[:,:,None,None]

    cdef StiffnessAssembler2D shared_clone(self):
        return self     # no shared data; class is thread-safe

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    cdef double assemble_impl(self, size_t[2] i, size_t[2] j) nogil:
        cdef int k
        cdef IntInterval intv
        cdef size_t g_sta[2]
        cdef size_t g_end[2]
        cdef (double*) values_i[2]
        cdef (double*) values_j[2]

        for k in range(2):
            intv = intersect_intervals(make_intv(self.meshsupp[k][i[k],0], self.meshsupp[k][i[k],1]),
                                       make_intv(self.meshsupp[k][j[k],0], self.meshsupp[k][j[k],1]))
            if intv.a >= intv.b:
                return 0.0      # no intersection of support
            g_sta[k] = self.nqp * intv.a    # start of Gauss nodes
            g_end[k] = self.nqp * intv.b    # end of Gauss nodes

            values_i[k] = &self.C[k][ i[k], g_sta[k], 0 ]
            values_j[k] = &self.C[k][ j[k], g_sta[k], 0 ]

        return combine_stiff_2d(
                self.B [ g_sta[0]:g_end[0], g_sta[1]:g_end[1] ],
                values_i[0], values_i[1],
                values_j[0], values_j[1])



################################################################################
# 3D Assemblers
################################################################################

cdef class BaseAssembler3D:
    cdef int nqp
    cdef size_t[3] ndofs
    cdef vector[ssize_t[:,::1]] meshsupp
    cdef list _asm_pool     # list of shared clones for multithreading

    cdef base_init(self, kvs):
        assert len(kvs) == 3, "Assembler requires three knot vectors"
        self.nqp = max([kv.p for kv in kvs]) + 1
        self.ndofs[:] = [kv.numdofs for kv in kvs]
        self.meshsupp = [kvs[k].mesh_support_idx_all() for k in range(3)]
        self._asm_pool = []

    cdef _share_base(self, BaseAssembler3D asm):
        asm.nqp = self.nqp
        asm.ndofs[:] = self.ndofs[:]
        asm.meshsupp = self.meshsupp

    cdef BaseAssembler3D shared_clone(self):
        return None     # not implemented

    cdef inline size_t to_seq(self, size_t[3] ii) nogil:
        # by convention, the order of indices is (z,y,x)
        return (ii[0] * self.ndofs[1] + ii[1]) * self.ndofs[2] + ii[2]

    @cython.cdivision(True)
    cdef inline void from_seq(self, size_t i, size_t[3] out) nogil:
        out[2] = i % self.ndofs[2]
        i /= self.ndofs[2]
        out[1] = i % self.ndofs[1]
        i /= self.ndofs[1]
        out[0] = i

    cdef double assemble_impl(self, size_t[3] i, size_t[3] j) nogil:
        return -9999.99  # Not implemented

    cpdef double assemble(self, size_t i, size_t j):
        cdef size_t[3] I, J
        with nogil:
            self.from_seq(i, I)
            self.from_seq(j, J)
            return self.assemble_impl(I, J)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void multi_assemble_chunk(self, size_t[:,::1] idx_arr, double[::1] out) nogil:
        cdef size_t[3] I, J
        cdef size_t k

        for k in range(idx_arr.shape[0]):
            self.from_seq(idx_arr[k,0], I)
            self.from_seq(idx_arr[k,1], J)
            out[k] = self.assemble_impl(I, J)

    def multi_assemble(self, indices):
        cdef size_t[:,::1] idx_arr = np.array(list(indices), dtype=np.uintp)
        cdef double[::1] result = np.empty(idx_arr.shape[0])

        num_threads = pyiga.get_max_threads()
        if num_threads <= 1:
            self.multi_assemble_chunk(idx_arr, result)
        else:
            thread_pool = get_thread_pool()
            if not self._asm_pool:
                self._asm_pool = [self] + [self.shared_clone()
                        for i in range(1, thread_pool._max_workers)]

            results = thread_pool.map(_asm_chunk_3d,
                        self._asm_pool,
                        chunk_tasks(idx_arr, num_threads),
                        chunk_tasks(result, num_threads))
            list(results)   # wait for threads to finish
        return result

cpdef void _asm_chunk_3d(BaseAssembler3D asm, size_t[:,::1] idxchunk, double[::1] out):
    with nogil:
        asm.multi_assemble_chunk(idxchunk, out)


cdef class MassAssembler3D(BaseAssembler3D):
    # shared data
    cdef vector[double[::1,:]] C
    cdef double[:,:,::1] geo_weights

    def __init__(self, kvs, geo):
        assert geo.dim == 3, "Geometry has wrong dimension"
        self.base_init(kvs)

        gauss = [make_iterated_quadrature(np.unique(kv.kv), self.nqp) for kv in kvs]
        gaussgrid = [g[0] for g in gauss]
        gaussweights = [g[1] for g in gauss]
        self.C  = [bspline.collocation(kvs[k], gaussgrid[k])
                   .toarray(order='F') for k in range(3)]

        geo_jac    = geo.grid_jacobian(gaussgrid)
        geo_det    = np.abs(determinants(geo_jac))
        self.geo_weights = gaussweights[0][:,None,None] * gaussweights[1][None,:,None] * gaussweights[2][None,None,:] * geo_det

    cdef MassAssembler3D shared_clone(self):
        return self     # no shared data; class is thread-safe

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    cdef double assemble_impl(self, size_t[3] i, size_t[3] j) nogil:
        cdef int k
        cdef IntInterval intv
        cdef size_t g_sta[3]
        cdef size_t g_end[3]
        cdef (double*) values_i[3]
        cdef (double*) values_j[3]

        for k in range(3):
            intv = intersect_intervals(make_intv(self.meshsupp[k][i[k],0], self.meshsupp[k][i[k],1]),
                                       make_intv(self.meshsupp[k][j[k],0], self.meshsupp[k][j[k],1]))
            if intv.a >= intv.b:
                return 0.0      # no intersection of support
            g_sta[k] = self.nqp * intv.a    # start of Gauss nodes
            g_end[k] = self.nqp * intv.b    # end of Gauss nodes

            values_i[k] = &self.C[k][ g_sta[k], i[k] ]
            values_j[k] = &self.C[k][ g_sta[k], j[k] ]

        return combine_mass_3d(
            self.geo_weights[ g_sta[0]:g_end[0], g_sta[1]:g_end[1], g_sta[2]:g_end[2] ],
            values_i[0], values_i[1], values_i[2],
            values_j[0], values_j[1], values_j[2]
        )


cdef class StiffnessAssembler3D(BaseAssembler3D):
    # shared data
    cdef vector[double[:, :, ::1]] C    # basis values. Indices: basis function, mesh point, derivative
    cdef double[:, :, :, :, ::1] B  # transformation matrix. Indices: 3 x mesh point, i, j

    def __init__(self, kvs, geo):
        assert geo.dim == 3, "Geometry has wrong dimension"
        self.base_init(kvs)

        gauss = [make_iterated_quadrature(np.unique(kv.kv), self.nqp) for kv in kvs]
        gaussgrid = [g[0] for g in gauss]
        gaussweights = [g[1] for g in gauss]
        colloc = [bspline.collocation_derivs(kvs[k], gaussgrid[k], derivs=1) for k in range(3)]
        self.C = [np.stack((X.T.A, Y.T.A), axis=-1) for (X,Y) in colloc]

        geo_jac = geo.grid_jacobian(gaussgrid)
        geo_det, geo_jacinv = det_and_inv(geo_jac)
        weights = gaussweights[0][:,None,None] * gaussweights[1][None,:,None] * gaussweights[2][None,None,:] * np.abs(geo_det)
        self.B = matmatT_3x3(geo_jacinv) * weights[:,:,:,None,None]

    cdef StiffnessAssembler3D shared_clone(self):
        return self     # no shared data; class is thread-safe

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    cdef double assemble_impl(self, size_t[3] i, size_t[3] j) nogil:
        cdef int k
        cdef IntInterval intv
        cdef size_t g_sta[3]
        cdef size_t g_end[3]
        cdef (double*) values_i[3]
        cdef (double*) values_j[3]

        for k in range(3):
            intv = intersect_intervals(make_intv(self.meshsupp[k][i[k],0], self.meshsupp[k][i[k],1]),
                                       make_intv(self.meshsupp[k][j[k],0], self.meshsupp[k][j[k],1]))
            if intv.a >= intv.b:
                return 0.0      # no intersection of support
            g_sta[k] = self.nqp * intv.a    # start of Gauss nodes
            g_end[k] = self.nqp * intv.b    # end of Gauss nodes

            values_i[k] = &self.C[k][ i[k], g_sta[k], 0 ]
            values_j[k] = &self.C[k][ j[k], g_sta[k], 0 ]

        return combine_stiff_3d(
                self.B [ g_sta[0]:g_end[0], g_sta[1]:g_end[1], g_sta[2]:g_end[2] ],
                values_i[0], values_i[1], values_i[2],
                values_j[0], values_j[1], values_j[2])



################################################################################
# Driver routines for 2D assemblers
################################################################################

@cython.boundscheck(False)
@cython.wraparound(False)
cdef object generic_assemble_2d(BaseAssembler2D asm, long chunk_start=-1, long chunk_end=-1):
    cdef size_t[2] i, j
    cdef size_t k, ii, jj
    cdef IntInterval intv

    cdef size_t[2] dof_start, dof_end, neigh_j_start, neigh_j_end
    cdef double entry
    cdef vector[double] entries
    cdef vector[size_t] entries_i, entries_j

    dof_start[:] = (0,0)
    dof_end[:] = asm.ndofs[:]

    if chunk_start >= 0:
        dof_start[0] = chunk_start
    if chunk_end >= 0:
        dof_end[0] = chunk_end

    i[:] = dof_start[:]
    with nogil:
        while True:         # loop over all i
            ii = asm.to_seq(i)

            for k in range(2):
                intv = find_joint_support_functions(asm.meshsupp[k], i[k])
                neigh_j_start[k] = intv.a
                neigh_j_end[k] = intv.b
            j[0] = neigh_j_start[0]
            j[1] = neigh_j_start[1]

            while True:     # loop j over all neighbors of i
                jj = asm.to_seq(j)
                if jj >= ii:
                    entry = asm.assemble_impl(i, j)

                    entries.push_back(entry)
                    entries_i.push_back(ii)
                    entries_j.push_back(jj)

                    if ii != jj:
                        entries.push_back(entry)
                        entries_i.push_back(jj)
                        entries_j.push_back(ii)

                if not next_lexicographic2(j, neigh_j_start, neigh_j_end):
                    break
            if not next_lexicographic2(i, dof_start, dof_end):
                break

    cdef size_t ne = entries.size()
    cdef size_t N = asm.ndofs[0] * asm.ndofs[1]
    return scipy.sparse.coo_matrix(
            (<double[:ne]> entries.data(),
                (<size_t[:ne]> entries_i.data(),
                 <size_t[:ne]> entries_j.data())),
            shape=(N,N)).tocsr()


cdef generic_assemble_2d_parallel(BaseAssembler2D asm):
    num_threads = pyiga.get_max_threads()
    if num_threads <= 1:
        return generic_assemble_2d(asm)
    def asm_chunk(rg):
        cdef BaseAssembler2D asm_clone = asm.shared_clone()
        return generic_assemble_2d(asm_clone, rg.start, rg.stop)
    results = get_thread_pool().map(asm_chunk, chunk_tasks(range_it(asm.ndofs[0]), 4*num_threads))
    return sum(results)


def mass_2d(kvs, geo):
    return generic_assemble_2d_parallel(MassAssembler2D(kvs, geo))

def stiffness_2d(kvs, geo):
    return generic_assemble_2d_parallel(StiffnessAssembler2D(kvs, geo))



################################################################################
# Driver routines for 3D assemblers
################################################################################

@cython.boundscheck(False)
@cython.wraparound(False)
cdef object generic_assemble_3d(BaseAssembler3D asm, long chunk_start=-1, long chunk_end=-1):
    cdef size_t[3] i, j
    cdef size_t k, ii, jj
    cdef IntInterval intv

    cdef size_t[3] dof_start, dof_end, neigh_j_start, neigh_j_end
    cdef double entry
    cdef vector[double] entries
    cdef vector[size_t] entries_i, entries_j

    dof_start[:] = (0,0,0)
    dof_end[:] = asm.ndofs[:]

    if chunk_start >= 0:
        dof_start[0] = chunk_start
    if chunk_end >= 0:
        dof_end[0] = chunk_end

    i[:] = dof_start[:]
    with nogil:
        while True:         # loop over all i
            ii = asm.to_seq(i)

            for k in range(3):
                intv = find_joint_support_functions(asm.meshsupp[k], i[k])
                neigh_j_start[k] = intv.a
                neigh_j_end[k] = intv.b
            j[0] = neigh_j_start[0]
            j[1] = neigh_j_start[1]
            j[2] = neigh_j_start[2]

            while True:     # loop j over all neighbors of i
                jj = asm.to_seq(j)
                if jj >= ii:
                    entry = asm.assemble_impl(i, j)

                    entries.push_back(entry)
                    entries_i.push_back(ii)
                    entries_j.push_back(jj)

                    if ii != jj:
                        entries.push_back(entry)
                        entries_i.push_back(jj)
                        entries_j.push_back(ii)

                if not next_lexicographic3(j, neigh_j_start, neigh_j_end):
                    break
            if not next_lexicographic3(i, dof_start, dof_end):
                break

    cdef size_t ne = entries.size()
    cdef size_t N = asm.ndofs[0] * asm.ndofs[1] * asm.ndofs[2]
    return scipy.sparse.coo_matrix(
            (<double[:ne]> entries.data(),
                (<size_t[:ne]> entries_i.data(),
                 <size_t[:ne]> entries_j.data())),
            shape=(N,N)).tocsr()


cdef generic_assemble_3d_parallel(BaseAssembler3D asm):
    num_threads = pyiga.get_max_threads()
    if num_threads <= 1:
        return generic_assemble_3d(asm)
    def asm_chunk(rg):
        cdef BaseAssembler3D asm_clone = asm.shared_clone()
        return generic_assemble_3d(asm_clone, rg.start, rg.stop)
    results = get_thread_pool().map(asm_chunk, chunk_tasks(range_it(asm.ndofs[0]), 4*num_threads))
    return sum(results)


def mass_3d(kvs, geo):
    return generic_assemble_3d_parallel(MassAssembler3D(kvs, geo))

def stiffness_3d(kvs, geo):
    return generic_assemble_3d_parallel(StiffnessAssembler3D(kvs, geo))



################################################################################
# Bindings for the C++ low-rank assembler (fastasm.cc)
################################################################################

cdef double _entry_func_2d(size_t i, size_t j, void * data):
    return (<BaseAssembler2D>data).assemble(i, j)

cdef double _entry_func_3d(size_t i, size_t j, void * data):
    return (<BaseAssembler3D>data).assemble(i, j)


def fast_mass_2d(kvs, geo, tol=1e-10, maxiter=100, skipcount=3, tolcount=3, verbose=2):
    cdef MassAssembler2D asm = MassAssembler2D(kvs, geo)
    return fast_assemble_cy.fast_assemble_2d_wrapper(_entry_func_2d, <void*>asm, kvs,
            tol, maxiter, skipcount, tolcount, verbose)

def fast_stiffness_2d(kvs, geo, tol=1e-10, maxiter=100, skipcount=3, tolcount=3, verbose=2):
    cdef StiffnessAssembler2D asm = StiffnessAssembler2D(kvs, geo)
    return fast_assemble_cy.fast_assemble_2d_wrapper(_entry_func_2d, <void*>asm, kvs,
            tol, maxiter, skipcount, tolcount, verbose)


def fast_mass_3d(kvs, geo, tol=1e-10, maxiter=100, skipcount=3, tolcount=3, verbose=2):
    cdef MassAssembler3D asm = MassAssembler3D(kvs, geo)
    return fast_assemble_cy.fast_assemble_3d_wrapper(_entry_func_3d, <void*>asm, kvs,
            tol, maxiter, skipcount, tolcount, verbose)

def fast_stiffness_3d(kvs, geo, tol=1e-10, maxiter=100, skipcount=3, tolcount=3, verbose=2):
    cdef StiffnessAssembler3D asm = StiffnessAssembler3D(kvs, geo)
    return fast_assemble_cy.fast_assemble_3d_wrapper(_entry_func_3d, <void*>asm, kvs,
            tol, maxiter, skipcount, tolcount, verbose)

