# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #

from testing import assert_equal, assert_true, assert_false
from test_utils import CopyCounter, MoveCopyCounter, DelRecorder
from utils.static_tuple import StaticTuple
from sys import size_of

from builtin.error import Errable

@fieldwise_init
struct CustomError[T: Copyable & Movable](Copyable, Errable, Movable, Stringable):
    var value: T

    fn __str__(self) -> String:
        return "CustomError"


def raise_an_error():
    raise Error("MojoError: This is an error!")


def test_error_raising():
    try:
        raise_an_error()
    except e:
        assert_equal(String(e), "MojoError: This is an error!")

def test_from_and_to_string():
    var my_string: String = "FOO"
    var error = Error(my_string)
    assert_equal(String(error), "FOO")

    assert_equal(String(Error("bad")), "bad")
    assert_equal(repr(Error("err")), "Error(err)")

def raise_custom_error():
    raise CustomError[UInt](42)

def test_error_custom_raising():
    try:
        raise_custom_error()
    except e:
        assert_true(Bool(e))
        assert_true(e.isa[CustomError[UInt]]())
        assert_false(e.isa[CustomError[Int]]())
        assert_equal(String(e), "CustomError")
        assert_equal(e[CustomError[UInt]].value, 42)

def test_error_correctly_calls_copyinit():
    alias error_type = CustomError[CopyCounter]
    var error = Error(error_type(CopyCounter()))
    assert_equal(error[error_type].value.copy_count, 0)

    var copy1 = error.copy()
    assert_equal(copy1[error_type].value.copy_count, 1)

    var copy2 = copy1.copy()
    assert_equal(copy2[error_type].value.copy_count, 2)

def test_error_does_not_call_moveinit_for_non_trivial_move_types():
    alias error_type = CustomError[MoveCopyCounter]

    constrained[not Bool(error_type.__moveinit__is_trivial)]()

    var error = Error(error_type(MoveCopyCounter()))

    # 2 initial moves -> one into the Error type and then one onto the heap
    assert_equal(error[error_type].value.moved, 2)

    var error2 = error^
    assert_equal(error2[error_type].value.moved, 2)

def test_error_calls_del():
    alias error_type = CustomError[DelRecorder]

    var dels = List[Int]()
    var error = Error(error_type(DelRecorder(42, UnsafePointer(to=dels))))

    assert_equal(len(dels), 0)

    # make sure __del__ is not called due to a move
    var error2 = error^
    assert_equal(len(dels), 0)

    _ = error2
    assert_equal(len(dels), 1)

fn error_is_inline[etype: Copyable & Movable](var value: etype) -> Bool:
    var error = Error(CustomError(value^))

    var original_address = Int(UnsafePointer(to=error[CustomError[etype]]))
    var moved_error = error^
    var moved_address = Int(UnsafePointer(to=moved_error[CustomError[etype]]))
    return original_address != moved_address

def test_error_correctly_inlines_acceptable_types():
    assert_true(error_is_inline(NoneType()))
    assert_true(error_is_inline(Int(42)))

    alias size_of_ptr = size_of[OpaquePointer]()
    assert_true(error_is_inline(StaticTuple[UInt8, size_of_ptr * 2](fill=0)))
    assert_false(error_is_inline(StaticTuple[UInt8, size_of_ptr * 2 + 1](fill=0)))

def test_default_error_evaluates_to_false():
    var error = Error()
    assert_false(Bool(error))


def main():
    test_error_raising()
    test_from_and_to_string()
    test_error_custom_raising()
    test_error_correctly_calls_copyinit()
    test_error_does_not_call_moveinit_for_non_trivial_move_types()
    test_error_calls_del()
    test_error_correctly_inlines_acceptable_types()
    test_default_error_evaluates_to_false()
