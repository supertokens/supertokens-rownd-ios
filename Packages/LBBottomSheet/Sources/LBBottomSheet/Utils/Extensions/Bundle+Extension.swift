//  Copyright © 2022 Lunabee Studio
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//  File.swift
//  LBBottomSheet
//
//  Created by Lunabee Studio / Date - 8/17/22 - for the LBBottomSheet Swift Package.
//

import Foundation

#if !SPM

extension Bundle {
    static var module: Bundle {
        let bundleName = "RowndLBBottomSheet"
        let containingBundle = Bundle(for: BottomSheetController.self)
        guard let url = containingBundle.url(forResource: bundleName, withExtension: "bundle"),
              let bundle = Bundle(url: url) else {
            preconditionFailure("Missing required resource bundle: \(bundleName).bundle")
        }

        return bundle
    }
}

#endif
