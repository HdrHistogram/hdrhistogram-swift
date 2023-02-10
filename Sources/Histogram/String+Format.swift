//
// Copyright (c) 2023 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  #error("Unsupported Platform")
#endif

extension String {
    /**
     * Simple printf-like formatting without Foundation.
     *
     * FIXME support String arguments
     */
    func format(_ arguments: CVarArg...) -> String {
        let n = withVaList(arguments) { va_list in
            return withCString { cString in
                return Int(vsnprintf(nil, 0, cString, va_list))
            }
        }

        return withVaList(arguments) { va_list in
            return withCString { cString in
                // need additional byte for terminating NUL
                return String(unsafeUninitializedCapacity: n + 1) {
                    return Int(vsnprintf($0.baseAddress, n + 1, cString, va_list))
                }
            }
        }
    }
}
