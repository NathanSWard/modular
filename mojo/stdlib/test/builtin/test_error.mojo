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

from testing import assert_equal, assert_true

from builtin.error import Errable


def raise_an_error():
    raise Error("MojoError: This is an error!")


def test_error_raising():
    try:
        raise_an_error()
    except e:
        assert_equal(String(e), "MojoError: This is an error!")


@fieldwise_init
@register_passable("trivial")
struct CustomError(Copyable, Errable, Movable, Representable, Stringable):
    var n: Int

    fn __str__(self) -> String:
        return "mojo " + String(self.n)

    fn __repr__(self) -> String:
        return String(self)


def raise_custom_error():
    raise CustomError(42)


def test_error_custom_raising():
    try:
        raise_custom_error()
    except e:
        assert_true(e.isa[CustomError]())
        assert_equal(String(e), "mojo 42")


def test_from_and_to_string():
    var my_string: String = "FOO"
    var error = Error(my_string)
    assert_equal(String(error), "FOO")

    assert_equal(String(Error("bad")), "bad")
    assert_equal(repr(Error("err")), "Error(err)")


def main():
    test_error_raising()
    test_from_and_to_string()
    test_error_custom_raising()
