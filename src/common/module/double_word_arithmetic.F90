! ====================================================================
!                    DOUBLE-WORD ARITHMETIC LIBRARY
! ====================================================================
! This file contains modules for performing double-word arithmetic
! with half, single, and double precision floating-point numbers.
! It also includes a conversion module to switch between standard
! real arrays and double-word arrays.
!
! Refactored to expand single-line procedures and add comments citing
! the algorithms from Joldes, Muller, Popescu, ACM TOMS (2017).
!
! Modules Provided:
!   - double_word_hp_module: For half-precision (real16) double-word arithmetic.
!   - double_word_sp_module: For single-precision (real32) double-word arithmetic.
!   - double_word_dp_module: For double-precision (real64) double-word arithmetic.
!   - double_word_conversion_module: For converting between types.
! ====================================================================

! ====================================================================
! HALF PRECISION MODULE (real16)
! ====================================================================
module double_word_hp_module
  use, intrinsic :: ieee_arithmetic, only : ieee_fma
  implicit none
  private

  integer, parameter :: hp = selected_real_kind(p=3, r=4)

  public :: hp, double_word_hp
  public :: operator(+), operator(-), operator(*), operator(/)
  public :: to_string

  type :: double_word_hp
    real(kind=hp) :: h = 0.0_hp
    real(kind=hp) :: l = 0.0_hp
  end type double_word_hp

  interface operator(+); procedure plus_dw_dw, plus_dw_fp, plus_fp_dw; end interface
  interface operator(-); procedure minus_dw_dw, minus_dw_fp, minus_fp_dw, negate_dw; end interface
  interface operator(*); procedure times_dw_dw, times_dw_fp, times_fp_dw; end interface
  interface operator(/); procedure div_dw_fp; end interface
  interface to_string; procedure to_string_hp; end interface

contains
  !> Computes s = fl(a+b) and t = a+b-s exactly. Implements Knuth/Møller's 2Sum.
  subroutine TwoSum(a, b, s, t)
    real(kind=hp), intent(in)  :: a, b
    real(kind=hp), intent(out) :: s, t
    real(kind=hp) :: ap, bp, da, db
    s = a + b
    ap = s - b
    bp = s - ap
    da = a - ap
    db = b - bp
    t = da + db
  end subroutine TwoSum

  !> Computes s = fl(a+b) and t = a+b-s exactly, assuming |a| >= |b|. Implements Dekker's Fast2Sum.
  subroutine Fast2Sum(a, b, s, t)
     real(kind=hp), intent(in)  :: a, b
     real(kind=hp), intent(out) :: s, t
     real(kind=hp) :: z
     s = a + b
     z = s - a
     t = b - z
  end subroutine Fast2Sum

  !> Computes p = fl(a*b) and r = a*b-p exactly. Implements Fast2Mult (Algorithm 3 from paper).
  subroutine TwoProd(a, b, p, r)
    real(kind=hp), intent(in)  :: a, b
    real(kind=hp), intent(out) :: p, r
    p = a * b
    r = ieee_fma(a, b, -p)
  end subroutine TwoProd

  function negate_dw(a) result(res)
    type(double_word_hp), intent(in) :: a
    type(double_word_hp)             :: res
    res%h = -a%h
    res%l = -a%l
  end function negate_dw

  !> Implements Algorithm 6: AccurateDWPlusDW
  function plus_dw_dw(a, b) result(res)
    type(double_word_hp), intent(in) :: a, b
    type(double_word_hp)             :: res
    real(kind=hp) :: sh, sl, th, tl, c, vh, vl, w
    call TwoSum(a%h, b%h, sh, sl)
    call TwoSum(a%l, b%l, th, tl)
    c = sl + th
    call Fast2Sum(sh, c, vh, vl)
    w = tl + vl
    call Fast2Sum(vh, w, res%h, res%l)
  end function plus_dw_dw

  !> Implements Algorithm 4: DWPlusFP
  function plus_dw_fp(a, b) result(res)
    type(double_word_hp), intent(in) :: a
    real(kind=hp), intent(in)        :: b
    type(double_word_hp)             :: res
    real(kind=hp) :: sh, sl, v
    call TwoSum(a%h, b, sh, sl)
    v = a%l + sl
    call Fast2Sum(sh, v, res%h, res%l)
  end function plus_dw_fp

  function plus_fp_dw(a, b) result(res)
    real(kind=hp), intent(in) :: a
    type(double_word_hp), intent(in) :: b
    type(double_word_hp)             :: res
    res = b + a
  end function plus_fp_dw

  function minus_dw_dw(a, b) result(res)
    type(double_word_hp), intent(in) :: a, b
    type(double_word_hp)             :: res
    res = a + (-b)
  end function minus_dw_dw

  function minus_dw_fp(a, b) result(res)
    type(double_word_hp), intent(in) :: a
    real(kind=hp), intent(in)        :: b
    type(double_word_hp)             :: res
    res = a + (-b)
  end function minus_dw_fp

  function minus_fp_dw(a, b) result(res)
    real(kind=hp), intent(in) :: a
    type(double_word_hp), intent(in) :: b
    type(double_word_hp)             :: res
    res = a + (-b)
  end function minus_fp_dw

  !> Implements Algorithm 11: DWTimesDW2 (FMA version)
  function times_dw_dw(a, b) result(res)
    type(double_word_hp), intent(in) :: a, b
    type(double_word_hp)             :: res
    real(kind=hp) :: ch, cl1, tl, cl2, cl3
    call TwoProd(a%h, b%h, ch, cl1)
    tl = a%h * b%l
    cl2 = ieee_fma(a%l, b%h, tl)
    cl3 = cl1 + cl2
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function times_dw_dw

  !> Implements Algorithm 9: DWTimesFP3 (FMA version)
  function times_dw_fp(a, b) result(res)
    type(double_word_hp), intent(in) :: a
    real(kind=hp), intent(in)        :: b
    type(double_word_hp)             :: res
    real(kind=hp) :: ch, cl1, cl3
    call TwoProd(a%h, b, ch, cl1)
    cl3 = ieee_fma(a%l, b, cl1)
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function times_dw_fp

  function times_fp_dw(a, b) result(res)
    real(kind=hp), intent(in) :: a
    type(double_word_hp), intent(in) :: b
    type(double_word_hp)             :: res
    res = b * a
  end function times_fp_dw

  !> Implements Algorithm 15: DWDivFP3
  function div_dw_fp(a, b) result(res)
    type(double_word_hp), intent(in) :: a
    real(kind=hp), intent(in)        :: b
    type(double_word_hp)             :: res
    real(kind=hp) :: th, ph, pl, dh, dt, d, tl
    th = a%h / b
    call TwoProd(th, b, ph, pl)
    dh = a%h - ph
    dt = dh - pl
    d = dt + a%l
    tl = d / b
    call Fast2Sum(th, tl, res%h, res%l)
  end function div_dw_fp

  function to_string_hp(a) result(s)
    type(double_word_hp), intent(in) :: a
    character(len=80)                :: s
    write(s, '(A, G0.5, A, G0.5, A)') '(', a%h, ' + ', a%l, ')'
  end function to_string_hp

end module double_word_hp_module

! ====================================================================
! SINGLE PRECISION MODULE (real32)
! ====================================================================
module double_word_sp_module
  use, intrinsic :: ieee_arithmetic, only : ieee_fma
  implicit none
  private

  integer, parameter :: sp = selected_real_kind(p=6, r=37)

  public :: sp, double_word_sp
  public :: operator(+), operator(-), operator(*), operator(/)
  public :: to_string

  type :: double_word_sp
    real(kind=sp) :: h = 0.0_sp
    real(kind=sp) :: l = 0.0_sp
  end type double_word_sp

  interface operator(+); procedure plus_dw_dw, plus_dw_fp, plus_fp_dw; end interface
  interface operator(-); procedure minus_dw_dw, minus_dw_fp, minus_fp_dw, negate_dw; end interface
  interface operator(*); procedure times_dw_dw, times_dw_fp, times_fp_dw; end interface
  interface operator(/); procedure div_dw_fp; end interface
  interface to_string; procedure to_string_sp; end interface

contains
  !> Computes s = fl(a+b) and t = a+b-s exactly. Implements Knuth/Møller's 2Sum.
  subroutine TwoSum(a, b, s, t)
    real(kind=sp), intent(in)  :: a, b
    real(kind=sp), intent(out) :: s, t
    real(kind=sp) :: ap, bp, da, db
    s = a + b
    ap = s - b
    bp = s - ap
    da = a - ap
    db = b - bp
    t = da + db
  end subroutine TwoSum

  !> Computes s = fl(a+b) and t = a+b-s exactly, assuming |a| >= |b|. Implements Dekker's Fast2Sum.
  subroutine Fast2Sum(a, b, s, t)
     real(kind=sp), intent(in)  :: a, b
     real(kind=sp), intent(out) :: s, t
     real(kind=sp) :: z
     s = a + b
     z = s - a
     t = b - z
  end subroutine Fast2Sum

  !> Computes p = fl(a*b) and r = a*b-p exactly. Implements Fast2Mult (Algorithm 3 from paper).
  subroutine TwoProd(a, b, p, r)
    real(kind=sp), intent(in)  :: a, b
    real(kind=sp), intent(out) :: p, r
    p = a * b
    r = ieee_fma(a, b, -p)
  end subroutine TwoProd

  function negate_dw(a) result(res)
    type(double_word_sp), intent(in) :: a
    type(double_word_sp)             :: res
    res%h = -a%h
    res%l = -a%l
  end function negate_dw

  !> Implements Algorithm 6: AccurateDWPlusDW
  function plus_dw_dw(a, b) result(res)
    type(double_word_sp), intent(in) :: a, b
    type(double_word_sp)             :: res
    real(kind=sp) :: sh, sl, th, tl, c, vh, vl, w
    call TwoSum(a%h, b%h, sh, sl)
    call TwoSum(a%l, b%l, th, tl)
    c = sl + th
    call Fast2Sum(sh, c, vh, vl)
    w = tl + vl
    call Fast2Sum(vh, w, res%h, res%l)
  end function plus_dw_dw

  !> Implements Algorithm 4: DWPlusFP
  function plus_dw_fp(a, b) result(res)
    type(double_word_sp), intent(in) :: a
    real(kind=sp), intent(in)        :: b
    type(double_word_sp)             :: res
    real(kind=sp) :: sh, sl, v
    call TwoSum(a%h, b, sh, sl)
    v = a%l + sl
    call Fast2Sum(sh, v, res%h, res%l)
  end function plus_dw_fp

  function plus_fp_dw(a, b) result(res)
    real(kind=sp), intent(in) :: a
    type(double_word_sp), intent(in) :: b
    type(double_word_sp)             :: res
    res = b + a
  end function plus_fp_dw

  function minus_dw_dw(a, b) result(res)
    type(double_word_sp), intent(in) :: a, b
    type(double_word_sp)             :: res
    res = a + (-b)
  end function minus_dw_dw

  function minus_dw_fp(a, b) result(res)
    type(double_word_sp), intent(in) :: a
    real(kind=sp), intent(in)        :: b
    type(double_word_sp)             :: res
    res = a + (-b)
  end function minus_dw_fp

  function minus_fp_dw(a, b) result(res)
    real(kind=sp), intent(in) :: a
    type(double_word_sp), intent(in) :: b
    type(double_word_sp)             :: res
    res = a + (-b)
  end function minus_fp_dw

  !> Implements Algorithm 11: DWTimesDW2 (FMA version)
  function times_dw_dw(a, b) result(res)
    type(double_word_sp), intent(in) :: a, b
    type(double_word_sp)             :: res
    real(kind=sp) :: ch, cl1, tl, cl2, cl3
    call TwoProd(a%h, b%h, ch, cl1)
    tl = a%h * b%l
    cl2 = ieee_fma(a%l, b%h, tl)
    cl3 = cl1 + cl2
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function times_dw_dw

  !> Implements Algorithm 9: DWTimesFP3 (FMA version)
  function times_dw_fp(a, b) result(res)
    type(double_word_sp), intent(in) :: a
    real(kind=sp), intent(in)        :: b
    type(double_word_sp)             :: res
    real(kind=sp) :: ch, cl1, cl3
    call TwoProd(a%h, b, ch, cl1)
    cl3 = ieee_fma(a%l, b, cl1)
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function times_dw_fp

  function times_fp_dw(a, b) result(res)
    real(kind=sp), intent(in) :: a
    type(double_word_sp), intent(in) :: b
    type(double_word_sp)             :: res
    res = b * a
  end function times_fp_dw

  !> Implements Algorithm 15: DWDivFP3
  function div_dw_fp(a, b) result(res)
    type(double_word_sp), intent(in) :: a
    real(kind=sp), intent(in)        :: b
    type(double_word_sp)             :: res
    real(kind=sp) :: th, ph, pl, dh, dt, d, tl
    th = a%h / b
    call TwoProd(th, b, ph, pl)
    dh = a%h - ph
    dt = dh - pl
    d = dt + a%l
    tl = d / b
    call Fast2Sum(th, tl, res%h, res%l)
  end function div_dw_fp

  function to_string_sp(a) result(s)
    type(double_word_sp), intent(in) :: a
    character(len=80)                :: s
    write(s, '(A, G0.8, A, G0.8, A)') '(', a%h, ' + ', a%l, ')'
  end function to_string_sp
end module double_word_sp_module

! ====================================================================
! DOUBLE PRECISION MODULE (real64)
! ====================================================================
module double_word_dp_module
  use, intrinsic :: ieee_arithmetic, only : ieee_fma
  implicit none
  private

  integer, parameter :: dp = selected_real_kind(p=15, r=307)

  public :: dp, double_word_dp
  public :: operator(+), operator(-), operator(*), operator(/)
  public :: to_string

  type :: double_word_dp
    real(kind=dp) :: h = 0.0_dp
    real(kind=dp) :: l = 0.0_dp
  end type double_word_dp

  interface operator(+); procedure plus_dw_dw, plus_dw_fp, plus_fp_dw; end interface
  interface operator(-); procedure minus_dw_dw, minus_dw_fp, minus_fp_dw, negate_dw; end interface
  interface operator(*); procedure times_dw_dw, times_dw_fp, times_fp_dw; end interface
  interface operator(/); procedure div_dw_fp; end interface
  interface to_string; procedure to_string_dp; end interface

contains
  !> Computes s = fl(a+b) and t = a+b-s exactly. Implements Knuth/Møller's 2Sum.
  subroutine TwoSum(a, b, s, t)
    real(kind=dp), intent(in)  :: a, b
    real(kind=dp), intent(out) :: s, t
    real(kind=dp) :: ap, bp, da, db
    s = a + b
    ap = s - b
    bp = s - ap
    da = a - ap
    db = b - bp
    t = da + db
  end subroutine TwoSum

  !> Computes s = fl(a+b) and t = a+b-s exactly, assuming |a| >= |b|. Implements Dekker's Fast2Sum.
  subroutine Fast2Sum(a, b, s, t)
     real(kind=dp), intent(in)  :: a, b
     real(kind=dp), intent(out) :: s, t
     real(kind=dp) :: z
     s = a + b
     z = s - a
     t = b - z
  end subroutine Fast2Sum

  !> Computes p = fl(a*b) and r = a*b-p exactly. Implements Fast2Mult (Algorithm 3 from paper).
  subroutine TwoProd(a, b, p, r)
    real(kind=dp), intent(in)  :: a, b
    real(kind=dp), intent(out) :: p, r
    p = a * b
    r = ieee_fma(a, b, -p)
  end subroutine TwoProd

  function negate_dw(a) result(res)
    type(double_word_dp), intent(in) :: a
    type(double_word_dp)             :: res
    res%h = -a%h
    res%l = -a%l
  end function negate_dw

  !> Implements Algorithm 6: AccurateDWPlusDW
  function plus_dw_dw(a, b) result(res)
    type(double_word_dp), intent(in) :: a, b
    type(double_word_dp)             :: res
    real(kind=dp) :: sh, sl, th, tl, c, vh, vl, w
    call TwoSum(a%h, b%h, sh, sl)
    call TwoSum(a%l, b%l, th, tl)
    c = sl + th
    call Fast2Sum(sh, c, vh, vl)
    w = tl + vl
    call Fast2Sum(vh, w, res%h, res%l)
  end function plus_dw_dw

  !> Implements Algorithm 4: DWPlusFP
  function plus_dw_fp(a, b) result(res)
    type(double_word_dp), intent(in) :: a
    real(kind=dp), intent(in)        :: b
    type(double_word_dp)             :: res
    real(kind=dp) :: sh, sl, v
    call TwoSum(a%h, b, sh, sl)
    v = a%l + sl
    call Fast2Sum(sh, v, res%h, res%l)
  end function plus_dw_fp

  function plus_fp_dw(a, b) result(res)
    real(kind=dp), intent(in) :: a
    type(double_word_dp), intent(in) :: b
    type(double_word_dp)             :: res
    res = b + a
  end function plus_fp_dw

  function minus_dw_dw(a, b) result(res)
    type(double_word_dp), intent(in) :: a, b
    type(double_word_dp)             :: res
    res = a + (-b)
  end function minus_dw_dw

  function minus_dw_fp(a, b) result(res)
    type(double_word_dp), intent(in) :: a
    real(kind=dp), intent(in)        :: b
    type(double_word_dp)             :: res
    res = a + (-b)
  end function minus_dw_fp

  function minus_fp_dw(a, b) result(res)
    real(kind=dp), intent(in) :: a
    type(double_word_dp), intent(in) :: b
    type(double_word_dp)             :: res
    res = a + (-b)
  end function minus_fp_dw

  !> Implements Algorithm 11: DWTimesDW2 (FMA version)
  function times_dw_dw(a, b) result(res)
    type(double_word_dp), intent(in) :: a, b
    type(double_word_dp)             :: res
    real(kind=dp) :: ch, cl1, tl, cl2, cl3
    call TwoProd(a%h, b%h, ch, cl1)
    tl = a%h * b%l
    cl2 = ieee_fma(a%l, b%h, tl)
    cl3 = cl1 + cl2
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function times_dw_dw

  !> Implements Algorithm 9: DWTimesFP3 (FMA version)
  function times_dw_fp(a, b) result(res)
    type(double_word_dp), intent(in) :: a
    real(kind=dp), intent(in)        :: b
    type(double_word_dp)             :: res
    real(kind=dp) :: ch, cl1, cl3
    call TwoProd(a%h, b, ch, cl1)
    cl3 = ieee_fma(a%l, b, cl1)
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function times_dw_fp

  function times_fp_dw(a, b) result(res)
    real(kind=dp), intent(in) :: a
    type(double_word_dp), intent(in) :: b
    type(double_word_dp)             :: res
    res = b * a
  end function times_fp_dw

  !> Implements Algorithm 15: DWDivFP3
  function div_dw_fp(a, b) result(res)
    type(double_word_dp), intent(in) :: a
    real(kind=dp), intent(in)        :: b
    type(double_word_dp)             :: res
    real(kind=dp) :: th, ph, pl, dh, dt, d, tl
    th = a%h / b
    call TwoProd(th, b, ph, pl)
    dh = a%h - ph
    dt = dh - pl
    d = dt + a%l
    tl = d / b
    call Fast2Sum(th, tl, res%h, res%l)
  end function div_dw_fp

  function to_string_dp(a) result(s)
    type(double_word_dp), intent(in) :: a
    character(len=80)                :: s
    write(s, '(A, G0.17, A, G0.17, A)') '(', a%h, ' + ', a%l, ')'
  end function to_string_dp
end module double_word_dp_module

! ====================================================================
! CONVERSION MODULE
! ====================================================================
module double_word_conversion_module
  use double_word_dp_module, only: dp, double_word_dp
  use double_word_sp_module, only: sp, double_word_sp
  use double_word_hp_module, only: hp, double_word_hp
  implicit none
  private

  public :: convert_dp_to_dw_sp, convert_dp_to_dw_dp, convert_dp_to_dw_hp
  public :: convert_dw_sp_to_dp, convert_dw_dp_to_dp, convert_dw_hp_to_dp

contains

  subroutine convert_dp_to_dw_hp(dp_array, dw_hp_array)
    real(kind=dp), dimension(:,:,:), intent(in) :: dp_array
    type(double_word_hp), dimension(:,:,:), intent(inout) :: dw_hp_array
    integer :: i, j, k
    real(kind=dp) :: dp_val
    real(kind=hp) :: h_part, l_part
    if (any(shape(dw_hp_array) /= shape(dp_array))) error stop "convert_dp_to_dw_hp: Shapes do not match."
    do k = 1, size(dp_array, 3)
      do j = 1, size(dp_array, 2)
        do i = 1, size(dp_array, 1)
          dp_val = dp_array(i, j, k)
          h_part = real(dp_val, kind=hp)
          l_part = real(dp_val - real(h_part, kind=dp), kind=hp)
          dw_hp_array(i, j, k) = double_word_hp(h_part, l_part)
        end do
      end do
    end do
  end subroutine

  subroutine convert_dp_to_dw_sp(dp_array, dw_sp_array)
    real(kind=dp), dimension(:,:,:), intent(in) :: dp_array
    type(double_word_sp), dimension(:,:,:), intent(inout) :: dw_sp_array
    integer :: i, j, k
    real(kind=dp) :: dp_val
    real(kind=sp) :: h_part, l_part
    if (any(shape(dw_sp_array) /= shape(dp_array))) error stop "convert_dp_to_dw_sp: Shapes do not match."
    do k = 1, size(dp_array, 3)
      do j = 1, size(dp_array, 2)
        do i = 1, size(dp_array, 1)
          dp_val = dp_array(i, j, k)
          h_part = real(dp_val, kind=sp)
          l_part = real(dp_val - real(h_part, kind=dp), kind=sp)
          dw_sp_array(i, j, k) = double_word_sp(h_part, l_part)
        end do
      end do
    end do
  end subroutine

  subroutine convert_dp_to_dw_dp(dp_array, dw_dp_array)
    real(kind=dp), dimension(:,:,:), intent(in) :: dp_array
    type(double_word_dp), dimension(:,:,:), intent(inout) :: dw_dp_array
    integer :: i, j, k
    if (any(shape(dw_dp_array) /= shape(dp_array))) error stop "convert_dp_to_dw_dp: Shapes do not match."
    do k = 1, size(dp_array, 3)
      do j = 1, size(dp_array, 2)
        do i = 1, size(dp_array, 1)
          dw_dp_array(i, j, k) = double_word_dp(dp_array(i, j, k), 0.0_dp)
        end do
      end do
    end do
  end subroutine

  subroutine convert_dw_hp_to_dp(dw_hp_array, dp_array)
    type(double_word_hp), dimension(:,:,:), intent(in) :: dw_hp_array
    real(kind=dp), dimension(:,:,:), intent(inout)   :: dp_array
    integer :: i, j, k
    type(double_word_hp) :: dw_val
    if (any(shape(dp_array) /= shape(dw_hp_array))) error stop "convert_dw_hp_to_dp: Shapes do not match."
    do k = 1, size(dw_hp_array, 3)
      do j = 1, size(dw_hp_array, 2)
        do i = 1, size(dw_hp_array, 1)
          dw_val = dw_hp_array(i, j, k)
          dp_array(i, j, k) = real(dw_val%h, kind=dp) + real(dw_val%l, kind=dp)
        end do
      end do
    end do
  end subroutine

  subroutine convert_dw_sp_to_dp(dw_sp_array, dp_array)
    type(double_word_sp), dimension(:,:,:), intent(in) :: dw_sp_array
    real(kind=dp), dimension(:,:,:), intent(inout)   :: dp_array
    integer :: i, j, k
    type(double_word_sp) :: dw_val
    if (any(shape(dp_array) /= shape(dw_sp_array))) error stop "convert_dw_sp_to_dp: Shapes do not match."
    do k = 1, size(dw_sp_array, 3)
      do j = 1, size(dw_sp_array, 2)
        do i = 1, size(dw_sp_array, 1)
          dw_val = dw_sp_array(i, j, k)
          dp_array(i, j, k) = real(dw_val%h, kind=dp) + real(dw_val%l, kind=dp)
        end do
      end do
    end do
  end subroutine

  subroutine convert_dw_dp_to_dp(dw_dp_array, dp_array)
    type(double_word_dp), dimension(:,:,:), intent(in) :: dw_dp_array
    real(kind=dp), dimension(:,:,:), intent(inout)   :: dp_array
    integer :: i, j, k
    type(double_word_dp) :: dw_val
    if (any(shape(dp_array) /= shape(dw_dp_array))) error stop "convert_dw_dp_to_dp: Shapes do not match."
    do k = 1, size(dw_dp_array, 3)
      do j = 1, size(dw_dp_array, 2)
        do i = 1, size(dw_dp_array, 1)
          dw_val = dw_dp_array(i, j, k)
          dp_array(i, j, k) = dw_val%h + dw_val%l
        end do
      end do
    end do
  end subroutine

end module double_word_conversion_module

module double_word_arithmetic
  use double_word_sp_module, only : dw => double_word_sp, rp => sp, operator(+), operator(-), operator(*), operator(/)
  use double_word_conversion_module, only : dw2dp => convert_dw_sp_to_dp
end module double_word_arithmetic
