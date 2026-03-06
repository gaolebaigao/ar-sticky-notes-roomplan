/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A custom button that stands out over the camera view.
*/

import UIKit

@IBDesignable
class RoundedButton: UIButton {
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    func setup() {
        AppTheme.styleFloatingButton(self)
        clipsToBounds = true
    }
    
    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1.0 : 0.52
        }
    }
    
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? UIColor.black.withAlphaComponent(0.62) : AppTheme.overlayBackground
        }
    }
}
