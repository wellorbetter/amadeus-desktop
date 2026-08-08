#pragma once

// Compatibility shim force-included (/FI) into webview_windows_plugin builds
// when using the Windows SDK 10.0.19041 cppwinrt headers with MSVC C++20.
//
// 1) ABI mode: winrt/base.h only enables the Windows ABI (guid <-> GUID/IID
//    conversions) when __IUnknown_INTERFACE_DEFINED__ is set, which normally
//    comes from including <wrl.h>/<unknwn.h> first. Our /FI is processed
//    before any plugin header, so include <unknwn.h> up front to restore it.
// 2) Two-phase lookup: winrt/impl/Windows.Foundation.0.h defines the
//    consume_Windows_Foundation_IAsync*::wait_for() members that call
//    winrt::impl::wait_for(Async const&, Windows::Foundation::TimeSpan const&),
//    but that overload is only *defined* later in winrt/Windows.Foundation.h.
//    Under C++20 two-phase name lookup the qualified name is resolved at the
//    definition site, so compilation fails with C2039
//    ("wait_for is not a member of winrt::impl").
//    Declaring the overload up front (after winrt/base.h, which provides the
//    TimeSpan alias) restores the correct lookup order.

#include <unknwn.h>

#include <winrt/base.h>

namespace winrt::impl {
template <typename Async>
auto wait_for(Async const& async, Windows::Foundation::TimeSpan const& timeout);
}  // namespace winrt::impl