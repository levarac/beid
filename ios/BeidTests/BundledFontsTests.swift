// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import UIKit
import XCTest

/// Pins the eight Flat 2b font files bundled and registered in `project.yml`
/// (beid#629). Every expected name is a literal, never read back from
/// `Bundle.main` or from the code under test. BeidTests is hosted by the
/// Beid app (`TEST_HOST = $(BUILT_PRODUCTS_DIR)/Beid.app/Beid`), so
/// `Bundle.main` here is the app bundle whose `UIAppFonts` iOS actually
/// registers — not the test bundle.
final class BundledFontsTests: XCTestCase {
  /// The PostScript names `Font.custom` must be given, paired with the file
  /// each one comes from. Both spellings matter: `UIAppFonts` lists files,
  /// while `UIFont(name:)` and `Font.custom` take PostScript names, and a
  /// mismatch between the two is invisible until a glyph renders wrong.
  private let expectedFaces: [(postScriptName: String, fileName: String)] = [
    ("BricolageGrotesque-Display60ExtraBold", "BricolageGrotesque-Display60ExtraBold.ttf"),
    ("BricolageGrotesque-Display52ExtraBold", "BricolageGrotesque-Display52ExtraBold.ttf"),
    ("BricolageGrotesque-Display46ExtraBold", "BricolageGrotesque-Display46ExtraBold.ttf"),
    ("BricolageGrotesque-Display40ExtraBold", "BricolageGrotesque-Display40ExtraBold.ttf"),
    ("BricolageGrotesque-Display34ExtraBold", "BricolageGrotesque-Display34ExtraBold.ttf"),
    ("DMSans-Bold", "DMSans-Bold.ttf"),
    ("DMSans-Regular", "DMSans-Regular.ttf"),
    ("DMMono-Medium", "DMMono-Medium.ttf"),
  ]

  /// Each bundled license, with the copyright line its family's `name` table
  /// declares. The OFL requires the license to travel with the font, and the
  /// three files are renamed per family because resources are flattened to
  /// the bundle root, where three files called `OFL.txt` would collide.
  private let expectedLicenses: [(fileName: String, copyright: String)] = [
    (
      "OFL-BricolageGrotesque.txt",
      "Copyright 2022 The Bricolage Grotesque Project Authors (https://github.com/ateliertriay/bricolage)"
    ),
    (
      "OFL-DMSans.txt",
      "Copyright 2014 The DM Sans Project Authors (https://github.com/googlefonts/dm-fonts)"
    ),
    (
      "OFL-DMMono.txt",
      "Copyright 2020 The DM Mono Project Authors (https://www.github.com/googlefonts/dm-mono)"
    ),
  ]

  /// A registered face resolves; an unregistered one does not. `UIFont(name:)`
  /// returns nil rather than substituting, and `fontName` is asserted too
  /// because a near-miss name can resolve to a *different* member of the same
  /// family. Together these catch the silent system-font fallback that
  /// `Font.custom` performs when `UIAppFonts` is missing or misspelt.
  func testEveryFlat2bPostScriptNameResolvesToItsOwnFace() {
    for face in expectedFaces {
      let font = UIFont(name: face.postScriptName, size: 17)
      XCTAssertNotNil(font, "UIFont(name: \"\(face.postScriptName)\") did not resolve")
      XCTAssertEqual(font?.fontName, face.postScriptName)
    }
  }

  /// `UIAppFonts` is what makes the files above loadable at all, so it is
  /// pinned exactly: a missing entry breaks a face, and an extra one names a
  /// file that is not there.
  func testUIAppFontsListsExactlyTheEightBundledFontFiles() {
    let registered = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]
    XCTAssertEqual(
      registered,
      [
        "BricolageGrotesque-Display60ExtraBold.ttf",
        "BricolageGrotesque-Display52ExtraBold.ttf",
        "BricolageGrotesque-Display46ExtraBold.ttf",
        "BricolageGrotesque-Display40ExtraBold.ttf",
        "BricolageGrotesque-Display34ExtraBold.ttf",
        "DMSans-Bold.ttf",
        "DMSans-Regular.ttf",
        "DMMono-Medium.ttf",
      ]
    )
    for face in expectedFaces {
      XCTAssertNotNil(
        Bundle.main.url(forResource: face.fileName, withExtension: nil),
        "\(face.fileName) is registered but not in the app bundle"
      )
    }
  }

  /// The OFL permits bundling only while the license travels with the font,
  /// so each license file must be present, be the OFL 1.1, and carry the
  /// copyright line of the family it covers.
  func testEachFamilyShipsItsOwnUnmodifiedOFLLicense() {
    for license in expectedLicenses {
      guard let url = Bundle.main.url(forResource: license.fileName, withExtension: nil) else {
        XCTFail("\(license.fileName) is not in the app bundle")
        continue
      }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        XCTFail("\(license.fileName) is not readable UTF-8")
        continue
      }
      XCTAssertTrue(
        text.contains("SIL Open Font License, Version 1.1"),
        "\(license.fileName) does not name the OFL 1.1"
      )
      XCTAssertTrue(
        text.contains(license.copyright),
        "\(license.fileName) does not carry its family's copyright line"
      )
    }
  }
}
