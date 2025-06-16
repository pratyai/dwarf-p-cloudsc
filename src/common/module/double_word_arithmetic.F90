! ====================================================================
!                    DOUBLE-WORD ARITHMETIC LIBRARY
! ====================================================================
! This file contains three self-contained, interchangeable modules
! for double-word arithmetic. Use only ONE module in your target files.
!
! To switch precision, change the module in the `use` statement, e.g.:
!   use double_word_sp_library
!     or
!   use double_word_dp_library
! ====================================================================

! ====================================================================
! HALF PRECISION LIBRARY (real16)
! ====================================================================
module double_word_hp_library
  use, intrinsic :: ieee_arithmetic, only : ieee_fma
  use, intrinsic :: iso_fortran_env
  implicit none
  private

  integer, parameter :: rp = real32
  integer, parameter :: source_rp = real64

  public :: rp, source_rp, double_word
  public :: operator(+), operator(-), operator(*), operator(/)
  public :: to_dw, from_dw, convert_array_to_dw, convert_array_from_dw
  public :: to_string

  type :: double_word
    real(kind=rp) :: h = 0.0_rp
    real(kind=rp) :: l = 0.0_rp
  end type double_word

  interface operator(+); procedure plus_dw_dw, plus_dw_fp, plus_fp_dw; end interface
  interface operator(-); procedure minus_dw_dw, minus_dw_fp, minus_fp_dw, negate_dw; end interface
  interface operator(*); procedure times_dw_dw, times_dw_fp, times_fp_dw; end interface
  interface operator(/); procedure div_dw_fp; end interface
  interface to_string; procedure to_string_proc; end interface

contains
  !> Computes s = fl(a+b) and t = a+b-s exactly. Implements Knuth/Møller's 2Sum.
  pure subroutine TwoSum(a, b, s, t)
    real(kind=rp), intent(in)  :: a, b
    real(kind=rp), intent(out) :: s, t
    real(kind=rp) :: ap, bp, da, db
    s = a + b
    ap = s - b
    bp = s - ap
    da = a - ap
    db = b - bp
    t = da + db
  end subroutine

  !> Computes s = fl(a+b) and t = a+b-s exactly, assuming |a| >= |b|. Implements Dekker's Fast2Sum.
  pure subroutine Fast2Sum(a, b, s, t)
     real(kind=rp), intent(in)  :: a, b
     real(kind=rp), intent(out) :: s, t
     real(kind=rp) :: z
     s = a + b
     z = s - a
     t = b - z
  end subroutine

  !> Computes p = fl(a*b) and r = a*b-p exactly. Implements Fast2Mult (Algorithm 3 from paper).
  pure subroutine TwoProd(a, b, p, r)
    real(kind=rp), intent(in)  :: a, b
    real(kind=rp), intent(out) :: p, r
    p = a * b
    r = ieee_fma(a, b, -p)
  end subroutine

  pure function negate_dw(a) result(res)
    type(double_word), intent(in) :: a
    type(double_word)             :: res
    res%h = -a%h
    res%l = -a%l
  end function

  !> Implements Algorithm 6: AccurateDWPlusDW
  pure function plus_dw_dw(a, b) result(res)
    type(double_word), intent(in) :: a, b
    type(double_word)             :: res
    real(kind=rp) :: sh, sl, th, tl, c, vh, vl, w
    call TwoSum(a%h, b%h, sh, sl)
    call TwoSum(a%l, b%l, th, tl)
    c = sl + th
    call Fast2Sum(sh, c, vh, vl)
    w = tl + vl
    call Fast2Sum(vh, w, res%h, res%l)
  end function

  !> Implements Algorithm 4: DWPlusFP
  pure function plus_dw_fp(a, b) result(res)
    type(double_word), intent(in) :: a
    real(kind=rp), intent(in)     :: b
    type(double_word)             :: res
    real(kind=rp) :: sh, sl, v
    call TwoSum(a%h, b, sh, sl)
    v = a%l + sl
    call Fast2Sum(sh, v, res%h, res%l)
  end function

  pure function plus_fp_dw(a, b) result(res)
    real(kind=rp), intent(in)     :: a
    type(double_word), intent(in) :: b
    type(double_word)             :: res
    res = b + a
  end function

  pure function minus_dw_dw(a, b) result(res)
    type(double_word), intent(in) :: a, b
    type(double_word)             :: res
    res = a + (-b)
  end function

  pure function minus_dw_fp(a, b) result(res)
    type(double_word), intent(in) :: a
    real(kind=rp), intent(in)     :: b
    type(double_word)             :: res
    res = a + (-b)
  end function

  pure function minus_fp_dw(a, b) result(res)
    real(kind=rp), intent(in)     :: a
    type(double_word), intent(in) :: b
    type(double_word)             :: res
    res = a + (-b)
  end function

  !> Implements Algorithm 11: DWTimesDW2 (FMA version)
  pure function times_dw_dw(a, b) result(res)
    type(double_word), intent(in) :: a, b
    type(double_word)             :: res
    real(kind=rp) :: ch, cl1, tl, cl2, cl3
    call TwoProd(a%h, b%h, ch, cl1)
    tl = a%h * b%l
    cl2 = ieee_fma(a%l, b%h, tl)
    cl3 = cl1 + cl2
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function

  !> Implements Algorithm 9: DWTimesFP3 (FMA version)
  pure function times_dw_fp(a, b) result(res)
    type(double_word), intent(in) :: a
    real(kind=rp), intent(in)     :: b
    type(double_word)             :: res
    real(kind=rp) :: ch, cl1, cl3
    call TwoProd(a%h, b, ch, cl1)
    cl3 = ieee_fma(a%l, b, cl1)
    call Fast2Sum(ch, cl3, res%h, res%l)
  end function

  pure function times_fp_dw(a, b) result(res)
    real(kind=rp), intent(in)     :: a
    type(double_word), intent(in) :: b
    type(double_word)             :: res
    res = b * a
  end function

  !> Implements Algorithm 15: DWDivFP3
  pure function div_dw_fp(a, b) result(res)
    type(double_word), intent(in) :: a
    real(kind=rp), intent(in)     :: b
    type(double_word)             :: res
    real(kind=rp) :: th, ph, pl, dh, dt, d, tl
    th = a%h / b
    call TwoProd(th, b, ph, pl)
    dh = a%h - ph
    dt = dh - pl
    d = dt + a%l
    tl = d / b
    call Fast2Sum(th, tl, res%h, res%l)
  end function

  function to_string_proc(a) result(s)
    type(double_word), intent(in) :: a
    character(len=80)             :: s
    write(s, '(A, G0.5, A, G0.5, A)') '(', a%h, ' + ', a%l, ')'
  end function

  ! --- Conversion Procedures ---
  pure function to_dw(x) result(y)
    real(kind=source_rp), intent(in) :: x
    type(double_word)               :: y
    y%h = real(x, kind=rp)
    y%l = real(x - real(y%h, kind=source_rp), kind=rp)
  end function

  pure function from_dw(y) result(x)
    type(double_word), intent(in) :: y
    real(kind=source_rp)          :: x
    x = real(y%h, kind=source_rp) + real(y%l, kind=source_rp)
  end function

  subroutine convert_array_to_dw(in_arr, out_arr)
    real(kind=source_rp), dimension(:,:,:), intent(in) :: in_arr
    type(double_word), dimension(:,:,:), intent(inout) :: out_arr
    integer :: i,j,k
    if(any(shape(out_arr)/=shape(in_arr))) error stop "to_dw array: Shapes mismatch."
    do k=1,size(in_arr,3); do j=1,size(in_arr,2); do i=1,size(in_arr,1)
      out_arr(i,j,k) = to_dw(in_arr(i,j,k))
    end do; end do; end do
  end subroutine

  subroutine convert_array_from_dw(in_arr, out_arr)
    type(double_word), dimension(:,:,:), intent(in) :: in_arr
    real(kind=source_rp), dimension(:,:,:), intent(inout) :: out_arr
    integer :: i,j,k
    if(any(shape(out_arr)/=shape(in_arr))) error stop "from_dw array: Shapes mismatch."
    do k=1,size(in_arr,3); do j=1,size(in_arr,2); do i=1,size(in_arr,1)
      out_arr(i,j,k) = from_dw(in_arr(i,j,k))
    end do; end do; end do
  end subroutine

end module double_word_hp_library

! ====================================================================
! SINGLE PRECISION LIBRARY (real32)
! ====================================================================
module double_word_sp_library
  use, intrinsic :: ieee_arithmetic, only : ieee_fma
  use, intrinsic :: iso_fortran_env
  implicit none
  private

  integer, parameter :: rp = real32
  integer, parameter :: source_rp = real64

  public :: rp, source_rp, double_word
  public :: operator(+), operator(-), operator(*), operator(/)
  public :: to_dw, from_dw, convert_array_to_dw, convert_array_from_dw
  public :: to_string

  type :: double_word
    real(kind=rp) :: h = 0.0_rp
    real(kind=rp) :: l = 0.0_rp
  end type double_word

  interface operator(+); procedure plus_dw_dw, plus_dw_fp, plus_fp_dw; end interface
  interface operator(-); procedure minus_dw_dw, minus_dw_fp, minus_fp_dw, negate_dw; end interface
  interface operator(*); procedure times_dw_dw, times_dw_fp, times_fp_dw; end interface
  interface operator(/); procedure div_dw_fp; end interface
  interface to_string; procedure to_string_proc; end interface

contains
  ! --- Arithmetic Procedures ---
  pure subroutine TwoSum(a, b, s, t)
    real(kind=rp), intent(in)  :: a, b
    real(kind=rp), intent(out) :: s, t
    real(kind=rp) :: ap, bp, da, db
    s=a+b; ap=s-b; bp=s-ap; da=a-ap; db=b-bp; t=da+db
  end subroutine
  pure subroutine Fast2Sum(a, b, s, t)
     real(kind=rp), intent(in)  :: a, b
     real(kind=rp), intent(out) :: s, t
     real(kind=rp) :: z
     s=a+b; z=s-a; t=b-z
  end subroutine
  pure subroutine TwoProd(a, b, p, r)
    real(kind=rp), intent(in)  :: a, b
    real(kind=rp), intent(out) :: p, r
    p = a*b; r = ieee_fma(a,b,-p)
  end subroutine
  pure function negate_dw(a) result(res)
    type(double_word), intent(in) :: a
    type(double_word)             :: res
    res%h=-a%h; res%l=-a%l
  end function
  pure function plus_dw_dw(a, b) result(res)
    type(double_word), intent(in) :: a, b
    type(double_word)             :: res
    real(kind=rp)::sh,sl,th,tl,c,vh,vl,w
    call TwoSum(a%h,b%h,sh,sl); call TwoSum(a%l,b%l,th,tl); c=sl+th; call Fast2Sum(sh,c,vh,vl)
    w=tl+vl; call Fast2Sum(vh,w,res%h,res%l)
  end function
  pure function plus_dw_fp(a, b) result(res)
    type(double_word), intent(in) :: a
    real(kind=rp), intent(in)     :: b
    type(double_word)             :: res
    real(kind=rp)::sh,sl,v
    call TwoSum(a%h,b,sh,sl); v=a%l+sl; call Fast2Sum(sh,v,res%h,res%l)
  end function
  pure function plus_fp_dw(a,b) result(res)
    real(kind=rp),intent(in)::a
    type(double_word),intent(in)::b
    type(double_word)             :: res
    res=b+a
  end function
  pure function minus_dw_dw(a,b) result(res)
    type(double_word),intent(in)::a,b
    type(double_word)             :: res
    res=a+(-b)
  end function
  pure function minus_dw_fp(a,b) result(res)
    type(double_word),intent(in)::a
    real(kind=rp),intent(in)     ::b
    type(double_word)             :: res
    res=a+(-b)
  end function
  pure function minus_fp_dw(a,b) result(res)
    real(kind=rp),intent(in)::a
    type(double_word),intent(in)::b
    type(double_word)             :: res
    res=a+(-b)
  end function
  pure function times_dw_dw(a,b) result(res)
    type(double_word),intent(in)::a,b
    type(double_word)             :: res
    real(kind=rp)::ch,cl1,tl,cl2,cl3
    call TwoProd(a%h,b%h,ch,cl1); tl=a%h*b%l; cl2=ieee_fma(a%l,b%h,tl); cl3=cl1+cl2
    call Fast2Sum(ch,cl3,res%h,res%l)
  end function
  pure function times_dw_fp(a,b) result(res)
    type(double_word),intent(in)::a
    real(kind=rp),intent(in)     ::b
    type(double_word)             :: res
    real(kind=rp)::ch,cl1,cl3
    call TwoProd(a%h,b,ch,cl1); cl3=ieee_fma(a%l,b,cl1); call Fast2Sum(ch,cl3,res%h,res%l)
  end function
  pure function times_fp_dw(a,b) result(res)
    real(kind=rp),intent(in)::a
    type(double_word),intent(in)::b
    type(double_word)             :: res
    res=b*a
  end function
  pure function div_dw_fp(a,b) result(res)
    type(double_word),intent(in)::a
    real(kind=rp),intent(in)     ::b
    type(double_word)             :: res
    real(kind=rp)::th,ph,pl,dh,dt,d,tl
    th=a%h/b; call TwoProd(th,b,ph,pl); dh=a%h-ph; dt=dh-pl; d=dt+a%l; tl=d/b
    call Fast2Sum(th,tl,res%h,res%l)
  end function
  function to_string_proc(a) result(s)
    type(double_word),intent(in)::a
    character(len=80)             ::s
    write(s,'(A,G0.8,A,G0.8,A)')'(',a%h,' + ',a%l,')'
  end function
  ! --- Conversion Procedures ---
  pure function to_dw(x) result(y)
    real(kind=source_rp), intent(in) :: x
    type(double_word)               :: y
    y%h = real(x, kind=rp)
    y%l = real(x - real(y%h, kind=source_rp), kind=rp)
  end function
  pure function from_dw(y) result(x)
    type(double_word), intent(in) :: y
    real(kind=source_rp)      :: x
    x = real(y%h, kind=source_rp) + real(y%l, kind=source_rp)
  end function
  subroutine convert_array_to_dw(in_arr, out_arr)
    real(kind=source_rp), dimension(:,:,:), intent(in) :: in_arr
    type(double_word), dimension(:,:,:), intent(inout) :: out_arr
    integer::i,j,k
    if(any(shape(out_arr)/=shape(in_arr))) error stop "to_dw array: Shapes mismatch."
    do k=1,size(in_arr,3); do j=1,size(in_arr,2); do i=1,size(in_arr,1)
      out_arr(i,j,k) = to_dw(in_arr(i,j,k))
    end do;end do;end do
  end subroutine
  subroutine convert_array_from_dw(in_arr, out_arr)
    type(double_word), dimension(:,:,:), intent(in) :: in_arr
    real(kind=source_rp), dimension(:,:,:), intent(inout) :: out_arr
    integer::i,j,k
    if(any(shape(out_arr)/=shape(in_arr))) error stop "from_dw array: Shapes mismatch."
    do k=1,size(in_arr,3); do j=1,size(in_arr,2); do i=1,size(in_arr,1)
      out_arr(i,j,k) = from_dw(in_arr(i,j,k))
    end do;end do;end do
  end subroutine
end module double_word_sp_library

! ====================================================================
! DOUBLE PRECISION LIBRARY (real64)
! ====================================================================
module double_word_dp_library
  use, intrinsic :: ieee_arithmetic, only : ieee_fma
  use, intrinsic :: iso_fortran_env
  implicit none
  private

  integer, parameter :: rp = real64
  integer, parameter :: source_rp = real64

  public :: rp, source_rp, double_word
  public :: operator(+), operator(-), operator(*), operator(/)
  public :: to_dw, from_dw, convert_array_to_dw, convert_array_from_dw
  public :: to_string

  type :: double_word
    real(kind=rp) :: h = 0.0_rp
    real(kind=rp) :: l = 0.0_rp
  end type double_word

  interface operator(+); procedure plus_dw_dw, plus_dw_fp, plus_fp_dw; end interface
  interface operator(-); procedure minus_dw_dw, minus_dw_fp, minus_fp_dw, negate_dw; end interface
  interface operator(*); procedure times_dw_dw, times_dw_fp, times_fp_dw; end interface
  interface operator(/); procedure div_dw_fp; end interface
  interface to_string; procedure to_string_proc; end interface

contains
  ! --- Arithmetic Procedures ---
  pure subroutine TwoSum(a, b, s, t)
    real(kind=rp), intent(in)  :: a, b
    real(kind=rp), intent(out) :: s, t
    real(kind=rp) :: ap, bp, da, db
    s=a+b; ap=s-b; bp=s-ap; da=a-ap; db=b-bp; t=da+db
  end subroutine
  pure subroutine Fast2Sum(a, b, s, t)
     real(kind=rp), intent(in)  :: a, b
     real(kind=rp), intent(out) :: s, t
     real(kind=rp) :: z
     s=a+b; z=s-a; t=b-z
  end subroutine
  pure subroutine TwoProd(a, b, p, r)
    real(kind=rp), intent(in)  :: a, b
    real(kind=rp), intent(out) :: p, r
    p = a*b; r = ieee_fma(a,b,-p)
  end subroutine
  pure function negate_dw(a) result(res)
    type(double_word), intent(in) :: a
    type(double_word)             :: res
    res%h=-a%h; res%l=-a%l
  end function
  pure function plus_dw_dw(a, b) result(res)
    type(double_word), intent(in) :: a, b
    type(double_word)             :: res
    real(kind=rp)::sh,sl,th,tl,c,vh,vl,w
    call TwoSum(a%h,b%h,sh,sl); call TwoSum(a%l,b%l,th,tl); c=sl+th; call Fast2Sum(sh,c,vh,vl)
    w=tl+vl; call Fast2Sum(vh,w,res%h,res%l)
  end function
  pure function plus_dw_fp(a, b) result(res)
    type(double_word), intent(in) :: a
    real(kind=rp), intent(in)     :: b
    type(double_word)             :: res
    real(kind=rp)::sh,sl,v
    call TwoSum(a%h,b,sh,sl); v=a%l+sl; call Fast2Sum(sh,v,res%h,res%l)
  end function
  pure function plus_fp_dw(a,b) result(res)
    real(kind=rp),intent(in)::a
    type(double_word),intent(in)::b
    type(double_word)             :: res
    res=b+a
  end function
  pure function minus_dw_dw(a,b) result(res)
    type(double_word),intent(in)::a,b
    type(double_word)             :: res
    res=a+(-b)
  end function
  pure function minus_dw_fp(a,b) result(res)
    type(double_word),intent(in)::a
    real(kind=rp),intent(in)     ::b
    type(double_word)             :: res
    res=a+(-b)
  end function
  pure function minus_fp_dw(a,b) result(res)
    real(kind=rp),intent(in)::a
    type(double_word),intent(in)::b
    type(double_word)             :: res
    res=a+(-b)
  end function
  pure function times_dw_dw(a,b) result(res)
    type(double_word),intent(in)::a,b
    type(double_word)             :: res
    real(kind=rp)::ch,cl1,tl,cl2,cl3
    call TwoProd(a%h,b%h,ch,cl1); tl=a%h*b%l; cl2=ieee_fma(a%l,b%h,tl); cl3=cl1+cl2
    call Fast2Sum(ch,cl3,res%h,res%l)
  end function
  pure function times_dw_fp(a,b) result(res)
    type(double_word),intent(in)::a
    real(kind=rp),intent(in)     ::b
    type(double_word)             :: res
    real(kind=rp)::ch,cl1,cl3
    call TwoProd(a%h,b,ch,cl1); cl3=ieee_fma(a%l,b,cl1); call Fast2Sum(ch,cl3,res%h,res%l)
  end function
  pure function times_fp_dw(a,b) result(res)
    real(kind=rp),intent(in)::a
    type(double_word),intent(in)::b
    type(double_word)             :: res
    res=b*a
  end function
  pure function div_dw_fp(a,b) result(res)
    type(double_word),intent(in)::a
    real(kind=rp),intent(in)     ::b
    type(double_word)             :: res
    real(kind=rp)::th,ph,pl,dh,dt,d,tl
    th=a%h/b; call TwoProd(th,b,ph,pl); dh=a%h-ph; dt=dh-pl; d=dt+a%l; tl=d/b
    call Fast2Sum(th,tl,res%h,res%l)
  end function
  function to_string_proc(a) result(s)
    type(double_word),intent(in)::a
    character(len=80)             ::s
    write(s,'(A,G0.17,A,G0.17,A)')'(',a%h,' + ',a%l,')'
  end function
  ! --- Conversion Procedures ---
  pure function to_dw(x) result(y)
    real(kind=source_rp), intent(in) :: x
    type(double_word)               :: y
    call Fast2Sum(x, 0.0_rp, y%h, y%l)
  end function
  pure function from_dw(y) result(x)
    type(double_word), intent(in) :: y
    real(kind=source_rp)      :: x
    x = y%h + y%l
  end function
  subroutine convert_array_to_dw(in_arr, out_arr)
    real(kind=source_rp), dimension(:,:,:), intent(in) :: in_arr
    type(double_word), dimension(:,:,:), intent(inout) :: out_arr
    integer::i,j,k
    if(any(shape(out_arr)/=shape(in_arr))) error stop "to_dw array: Shapes mismatch."
    do k=1,size(in_arr,3); do j=1,size(in_arr,2); do i=1,size(in_arr,1)
      out_arr(i,j,k) = to_dw(in_arr(i,j,k))
    end do;end do;end do
  end subroutine
  subroutine convert_array_from_dw(in_arr, out_arr)
    type(double_word), dimension(:,:,:), intent(in) :: in_arr
    real(kind=source_rp), dimension(:,:,:), intent(inout) :: out_arr
    integer::i,j,k
    if(any(shape(out_arr)/=shape(in_arr))) error stop "from_dw array: Shapes mismatch."
    do k=1,size(in_arr,3); do j=1,size(in_arr,2); do i=1,size(in_arr,1)
      out_arr(i,j,k) = from_dw(in_arr(i,j,k))
    end do;end do;end do
  end subroutine
end module double_word_dp_library
