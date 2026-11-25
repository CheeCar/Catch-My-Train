#!/bin/bash
# Run after `xcodegen generate` from the project root: XcodeGen names the product files after the targets,
# but PRODUCT_NAME makes them "Catch My Train.app" and "Catch My Train Widget.appex".
set -euo pipefail
P=CatchMyTrain.xcodeproj/project.pbxproj
sed -i.bak 's|path = CatchMyTrain.app;|path = "Catch My Train.app";|; s|path = CatchMyTrainWidgetExtension.appex;|path = "Catch My Train Widget.appex";|' "$P"
for S in CatchMyTrain.xcodeproj/xcshareddata/xcschemes/*.xcscheme; do
    sed -i.bak 's|BuildableName = "CatchMyTrain.app"|BuildableName = "Catch My Train.app"|; s|BuildableName = "CatchMyTrainWidgetExtension.appex"|BuildableName = "Catch My Train Widget.appex"|' "$S"
done
rm -f "$P.bak" CatchMyTrain.xcodeproj/xcshareddata/xcschemes/*.bak
