#import <AppKit/AppKit.h>
#include <stdio.h>
int main(void) {
 NSAutoreleasePool *p=[NSAutoreleasePool new]; [NSApplication sharedApplication];
 NSColorList *disk=[[NSColorList alloc] initWithName:@"System" fromFile:@"/System/Library/Themes/Eau.theme/Resources/ThemeColors.clr"];
 NSColorList *live=[NSColorList colorListNamed:@"System"];
 NSArray *expected=[NSArray arrayWithObjects: @"alternateSelectedControlColor", @"alternateSelectedControlTextColor", @"controlBackgroundColor", @"controlColor", @"controlDarkShadowColor", @"controlHighlightColor", @"controlLightHighlightColor", @"controlShadowColor", @"controlTextColor", @"disabledControlTextColor", @"gridColor", @"headerColor", @"headerTextColor", @"highlightColor", @"keyboardFocusIndicatorColor", @"knobColor", @"labelColor", @"quaternaryLabelColor", @"scrollBarColor", @"secondaryLabelColor", @"secondarySelectedControlColor", @"selectedControlColor", @"selectedControlTextColor", @"selectedKnobColor", @"selectedMenuItemColor", @"selectedMenuItemTextColor", @"selectedTextBackgroundColor", @"selectedTextColor", @"shadowColor", @"tertiaryLabelColor", @"textBackgroundColor", @"textColor", @"windowBackgroundColor", @"windowFrameColor", @"windowFrameTextColor", @"rowBackgroundColor", @"alternateRowBackgroundColor", @"toolTipColor", @"toolTipTextColor", nil];
 unsigned lost=0, needed=0, missing=0;
 for (NSString *k in [disk allKeys]) if (![[disk colorWithKey:k] isEqual:[live colorWithKey:k]]) lost++;
 for (NSString *k in expected) { if (![disk colorWithKey:k]) needed++; if (![live colorWithKey:k]) missing++; }
 fprintf(stderr,"disk=%lu live=%lu lost=%u fallback-needed=%u fallback-missing=%u live-editable=%d\n",(unsigned long)[[disk allKeys] count],(unsigned long)[[live allKeys] count],lost,needed,missing,[live isEditable]);
 [disk release]; [p drain]; return (lost || missing || !needed) ? 1 : 0;
}
