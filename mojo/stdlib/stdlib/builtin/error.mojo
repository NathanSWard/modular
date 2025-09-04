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
"""Implements the Error class.

These are Mojo built-ins, so you don't need to import them.
"""

from builtin.debug_assert import debug_assert
from collections.inline_array import InlineArray
from collections.string.format import _CurlyEntryFormattable
from compile.reflection import get_type_name
from os import abort
from sys import external_call, is_gpu, _libc
from sys.ffi import c_char
from sys.info import size_of, align_of
from utils.static_tuple import StaticTuple

from memory import memcpy, ArcPointer
from memory.unsafe_pointer import OpaquePointer
from memory.maybe_uninitialized import UnsafeMaybeUninitialized
from io.write import _WriteBufferStack


# ===-----------------------------------------------------------------------===#
# StackTrace
# ===-----------------------------------------------------------------------===#
@register_passable
struct StackTrace(Copyable, Stringable):
    """Holds a stack trace of a location when StackTrace is constructed."""

    var value: ArcPointer[UnsafePointer[UInt8]]
    """A reference counting pointer to a char array containing the stack trace."""

    @always_inline("nodebug")
    fn __init__(out self):
        """Construct an empty stack trace."""
        self.value = ArcPointer(UnsafePointer[UInt8]())

    @always_inline("nodebug")
    fn __init__(out self, *, depth: Int):
        """Construct a new stack trace.

        Args:
            depth: The depth of the stack trace.
                   When `depth` is zero, entire stack trace is collected.
                   When `depth` is negative, no stack trace is collected.
        """

        @parameter
        if is_gpu():
            self = StackTrace()
            return

        if depth < 0:
            self = StackTrace()
            return

        var buffer = UnsafePointer[UInt8]()
        var num_bytes = external_call["KGEN_CompilerRT_GetStackTrace", Int](
            UnsafePointer(to=buffer), depth
        )
        # When num_bytes is zero, the stack trace was not collected.
        if num_bytes == 0:
            self.value = ArcPointer(UnsafePointer[UInt8]())
            return

        var ptr = UnsafePointer[UInt8]().alloc(num_bytes)
        self.value = ArcPointer[UnsafePointer[UInt8]](ptr)
        memcpy(self.value[], buffer, num_bytes)
        # Explicitly free the buffer using free() instead of the Mojo allocator.
        _libc.free(buffer.bitcast[NoneType]())

    fn __copyinit__(out self, existing: Self):
        """Creates a copy of an existing stack trace.

        Args:
            existing: The stack trace to copy from.
        """
        self.value = existing.value

    fn __str__(self) -> String:
        """Converts the StackTrace to string representation.

        Returns:
            A String of the stack trace.
        """
        if not self.value[]:
            return (
                "stack trace was not collected. Enable stack trace collection"
                " with environment variable `MOJO_ENABLE_STACK_TRACE_ON_ERROR`"
            )
        return String(unsafe_from_utf8_ptr=self.value[])


# ===-----------------------------------------------------------------------===#
# Errable
# ===-----------------------------------------------------------------------===#


trait Errable(Copyable, Movable, Stringable):
    pass


@fieldwise_init
@register_passable("trivial")
struct _ErrorVTableOp(Copyable, Movable):
    var value: Int

    alias Destroy = Self(0)
    alias Copy = Self(1)
    alias Str = Self(3)
    alias IsA = Self(4)
    alias IsAlive = Self(5)

    @always_inline
    fn __is__(self, other: Self) -> Bool:
        return self.value == other.value


@fieldwise_init
@register_passable("trivial")
struct _Tag[etype: Errable]:
    pass


@register_passable
struct _ErrorVTable(Copyable, Movable):
    var _dispatch: fn (
        op: _ErrorVTableOp, *,
        input: OpaquePointer,
        output: OpaquePointer,
    ) -> Bool

    fn __init__(out self):
        _ = self._dispatch = Self.noop_dispatch

    fn __init__[etype: Errable](out self, tag: _Tag[etype]):
        _ = self._dispatch = Self.dispatch_op[etype]

    @staticmethod
    fn _destroy_error_impl[etype: Errable](error: OpaquePointer):
        var erased_pointer = error.bitcast[_MaybeInlineErasedPointer]()
        erased_pointer.take_pointee().free_typed[etype]()

    fn destroy_error(self, erased_pointer: _MaybeInlineErasedPointer):
        _ = self._dispatch(
            _ErrorVTableOp.Destroy,
            input=UnsafePointer(to=erased_pointer).bitcast[NoneType](),
            output=OpaquePointer(),
        )

    @staticmethod
    fn _copy_error_impl[
        etype: Errable
    ](input: OpaquePointer, output: OpaquePointer):
        var existing = input.bitcast[_MaybeInlineErasedPointer]()
        var uninit = output.bitcast[UnsafeMaybeUninitialized[_MaybeInlineErasedPointer]]()

        uninit[].write(_MaybeInlineErasedPointer(existing[].copy_typed[etype]()))

    fn copy_error(
        self,
        erased_pointer: _MaybeInlineErasedPointer,
    ) -> _MaybeInlineErasedPointer:
        var copy = UnsafeMaybeUninitialized[_MaybeInlineErasedPointer]()
        _ = self._dispatch(
            _ErrorVTableOp.Copy,
            input=UnsafePointer(to=erased_pointer).bitcast[NoneType](),
            output=UnsafePointer(to=copy).bitcast[NoneType](),
        )
        return copy.unsafe_ptr().take_pointee()

    @staticmethod
    fn _str_error_impl[
        etype: Errable
    ](input: OpaquePointer, output: OpaquePointer):
        var ptr = input.bitcast[_MaybeInlineErasedPointer]()[].get_pointer[etype]()
        var string = ptr[].__str__()
        output.bitcast[UnsafeMaybeUninitialized[String]]()[].write(string^)

    fn str_error(self, error: _MaybeInlineErasedPointer) -> String:
        var string = UnsafeMaybeUninitialized[String]()
        _ = self._dispatch(
            _ErrorVTableOp.Str,
            input=UnsafePointer(to=error).bitcast[NoneType](),
            output=UnsafePointer(to=string).bitcast[NoneType](),
        )
        return string.unsafe_ptr().take_pointee()

    @staticmethod
    fn _isa_error_impl[
        etype: Errable
    ](input: OpaquePointer, output: OpaquePointer):
        alias error_type_name = get_type_name[etype, qualified_builtins=True]()
        var checked_type_name = input.bitcast[StaticString]()[]
        var success = error_type_name == checked_type_name
        output.bitcast[Bool]()[] = success

    fn isa_error[etype: Errable](self) -> Bool:
        var success = False
        alias type_name = get_type_name[etype, qualified_builtins=True]()
        _ = self._dispatch(
            _ErrorVTableOp.IsA,
            input=UnsafePointer(to=type_name).bitcast[NoneType](),
            output=UnsafePointer(to=success).bitcast[NoneType](),
        )
        return success

    fn __bool__(self) -> Bool:
        return self._dispatch(
            _ErrorVTableOp.IsAlive,
            input=OpaquePointer(),
            output=OpaquePointer(),
        )

    @staticmethod
    fn noop_dispatch(
        op: _ErrorVTableOp, error: OpaquePointer, result: OpaquePointer
    ) -> Bool:
        return False

    @staticmethod
    fn dispatch_op[
        etype: Errable
    ](op: _ErrorVTableOp, input: OpaquePointer, output: OpaquePointer) -> Bool:
        if op is _ErrorVTableOp.Destroy:
            Self._destroy_error_impl[etype](input)
        elif op is _ErrorVTableOp.Copy:
            Self._copy_error_impl[etype](input, output)
        elif op is _ErrorVTableOp.Str:
            Self._str_error_impl[etype](input, output)
        elif op is _ErrorVTableOp.IsA:
            Self._isa_error_impl[etype](input, output)
        elif op is _ErrorVTableOp.IsAlive:
            pass

        return True

@register_passable
struct _MaybeInlineErasedPointer:
    alias storage_type = StaticTuple[OpaquePointer, 2]
    var storage_or_pointer: Self.storage_type

    fn __init__(out self):
        self.storage_or_pointer = StaticTuple[OpaquePointer, 2](fill=OpaquePointer())

    fn __init__[T: AnyType & Movable](out self, var value: T):
        self.storage_or_pointer = StaticTuple[OpaquePointer, 2](fill=OpaquePointer())

        @parameter
        if Self.is_inlineable[T]():
            UnsafePointer(to=self.storage_or_pointer).bitcast[T]().init_pointee_move(value^)
        else:
            var allocation = UnsafePointer[T].alloc(1)
            allocation.init_pointee_move(value^)
            self.storage_or_pointer[0] = allocation.bitcast[NoneType]()

    @staticmethod
    fn is_inlineable[T: AnyType & Movable]() -> Bool:
        return (
            size_of[T]() <= size_of[Self.storage_type]()
            and align_of[T]() <= align_of[Self.storage_type]()
            and Bool(T.__moveinit__is_trivial)
        )

    fn _pointer_to_heap(self) -> OpaquePointer:
        return self.storage_or_pointer[0]

    fn _pointer_to_inline(self) -> OpaquePointer:
        return UnsafePointer(to=self.storage_or_pointer).bitcast[NoneType]()

    fn get_pointer[origin: Origin, //, T: AnyType & Movable](ref [origin] self) -> UnsafePointer[T, mut=origin.mut, origin = origin]:
        @parameter
        if Self.is_inlineable[T]():
            return self._pointer_to_inline().bitcast[T]()
        else:
            return self._pointer_to_heap().bitcast[T]()

    fn copy_typed[T: ExplicitlyCopyable & Movable](self) -> T:
        return self.get_pointer[T]()[].copy()

    fn free_typed[T: AnyType & Movable](deinit self):
        var pointer = self.get_pointer[T]()
        pointer.destroy_pointee()

        @parameter
        if not Self.is_inlineable[T]():
            pointer.free()


struct _TypeErasedError(Copyable, Movable, Stringable):
    var data: _MaybeInlineErasedPointer
    var vtable: _ErrorVTable

    @always_inline
    fn __init__(out self):
        """Default constructor."""
        self.data = _MaybeInlineErasedPointer()
        self.vtable = _ErrorVTable()

    fn __init__[etype: Errable, //](out self, var error: etype):
        self.data = _MaybeInlineErasedPointer(error^)
        self.vtable = _ErrorVTable(_Tag[etype]())

    fn __copyinit__(out self, existing: Self):
        self.data = existing.vtable.copy_error(existing.data)
        self.vtable = existing.vtable

    fn __del__(deinit self):
        self.vtable.destroy_error(self.data^)

    fn __bool__(self) -> Bool:
        """Returns True if the error is set and false otherwise.

        Returns:
          True if the error object contains a value and False otherwise.
        """
        return self.vtable.__bool__()

    fn __str__(self) -> String:
        return self.vtable.str_error(self.data)

    fn isa[etype: Errable](self) -> Bool:
        """Todo."""
        var success = self.vtable.isa_error[etype]()
        return success


# ===-----------------------------------------------------------------------===#
# Error
# ===-----------------------------------------------------------------------===#


struct Error(
    Boolable,
    Copyable,
    Defaultable,
    ExplicitlyCopyable,
    Movable,
    Representable,
    Stringable,
    Writable,
    _CurlyEntryFormattable,
):
    """This type represents an Error."""

    # ===-------------------------------------------------------------------===#
    # Fields
    # ===-------------------------------------------------------------------===#

    var data: _TypeErasedError
    var stack_trace: StackTrace

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    fn __init__(out self):
        """Default constructor."""
        self.data = _TypeErasedError()
        self.stack_trace = StackTrace(depth=-1)

    @implicit
    fn __init__[etype: Errable, //](out self, var error: etype):
        """Construct an Error object with a given error type.

        Args:
            error: The error.
        """

        self.data = _TypeErasedError(error^)
        self.stack_trace = StackTrace(depth=0)

    @no_inline
    fn __init__[
        *Ts: Writable
    ](out self, *args: *Ts, sep: StaticString = "", end: StaticString = "",):
        """
        Construct an Error by concatenating a sequence of Writable arguments.

        Args:
            args: A sequence of Writable arguments.
            sep: The separator used between elements.
            end: The String to write after printing the elements.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
                `Writable`.
        """
        var output = String()
        var buffer = _WriteBufferStack(output)

        @parameter
        for i in range(args.__len__()):
            args[i].write_to(buffer)

        buffer.flush()
        self = Error(output^)

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    fn __bool__(self) -> Bool:
        """Returns True if the error is set and false otherwise.

        Returns:
          True if the error object contains a value and False otherwise.
        """
        return self.data.__bool__()

    @no_inline
    fn __str__(self) -> String:
        """Converts the Error to string representation.

        Returns:
            A String of the error message.
        """

        return self.data.__str__()

    @no_inline
    fn write_to(self, mut writer: Some[Writer]):
        """
        Formats this error to the provided Writer.

        Args:
            writer: The object to write to.
        """

        if not self:
            return

        writer.write(self.__str__())

    fn __repr__(self) -> String:
        """Converts the Error to printable representation.

        Returns:
            A printable representation of the error message.
        """

        return String("Error(", self.__str__(), ")")

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    fn isa[etype: Errable](self) -> Bool:
        """Todo."""

        return self.data.isa[etype]()

    fn __getitem__[etype: Errable](ref self) -> ref [self] etype:
        """Todo."""
        if not self.isa[etype]():
            abort("__getitem__: incorrect error type")

        return self.unsafe_get[etype]()

    fn unsafe_get[etype: Errable](ref self) -> ref [self] etype:
        """Todo."""

        return self.data.data.get_pointer[etype]().origin_cast[origin=__origin_of(self)]()[]

    fn get_stack_trace(self) -> StackTrace:
        """Returns the stack trace of the error.

        Returns:
            The stringable stack trace of the error.
        """
        return self.stack_trace

    fn is_inline[etype: Errable](self) -> Bool:
        return _MaybeInlineErasedPointer.is_inlineable[etype]()


@doc_private
fn __mojo_debugger_raise_hook():
    """This function is used internally by the Mojo Debugger."""
    pass
