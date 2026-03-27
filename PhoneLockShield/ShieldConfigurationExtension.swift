//
//  ShieldConfigurationExtension.swift
//  PhoneLockShield
//

import ManagedSettings
import ManagedSettingsUI
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        shieldForBlockedContent()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        shieldForBlockedContent()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        shieldForBlockedContent()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        shieldForBlockedContent()
    }

    private func shieldForBlockedContent() -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundColor: .black,
            icon: PhoneLockShieldLogo.shieldIconImage(),
            title: ShieldConfiguration.Label(text: "PhoneLockAI", color: .white),
            subtitle: ShieldConfiguration.Label(text: "PhoneLockAI has Locked This App", color: .lightGray)
        )
    }
}

private enum PhoneLockShieldLogo {
    private static let assetName = "PhoneLockAILogo"
    /// Longest edge of the logo image (3× the previous 120pt cap).
    private static let maxIconSide: CGFloat = 360

    /// Uses `PhoneLockAILogo` from the extension asset catalog (`PhoneLockAILogo.png` in `PhoneLockAILogo.imageset`).
    static func shieldIconImage() -> UIImage {
        if let fromAsset = UIImage(named: assetName, in: Bundle.main, compatibleWith: nil) {
            return scaledForShieldIcon(fromAsset)
        }
        return fallbackGeneratedImage()
    }

    private static func scaledForShieldIcon(_ image: UIImage) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > 0 else { return image }
        let scale = maxIconSide / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func fallbackGeneratedImage() -> UIImage {
        let side = maxIconSide
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.systemBlue.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 90, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let text = "PL" as NSString
            let textSize = text.size(withAttributes: attrs)
            let origin = CGPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2
            )
            text.draw(at: origin, withAttributes: attrs)
        }
    }
}
