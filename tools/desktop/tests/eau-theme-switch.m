#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#include <stdio.h>
int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [NSApplication sharedApplication];
  GSTheme *eau = [[GSTheme theme] retain];
  NSColorList *disk = [[NSColorList alloc] initWithName:@"System" fromFile:@"/System/Library/Themes/Eau.theme/Resources/ThemeColors.clr"];
  NSArray *fallback = [NSArray arrayWithObjects: @"alternateSelectedControlColor", @"alternateSelectedControlTextColor", @"controlBackgroundColor", @"controlColor", @"controlDarkShadowColor", @"controlHighlightColor", @"controlLightHighlightColor", @"controlShadowColor", @"controlTextColor", @"disabledControlTextColor", @"gridColor", @"headerColor", @"headerTextColor", @"highlightColor", @"keyboardFocusIndicatorColor", @"knobColor", @"labelColor", @"quaternaryLabelColor", @"scrollBarColor", @"secondaryLabelColor", @"secondarySelectedControlColor", @"selectedControlColor", @"selectedControlTextColor", @"selectedKnobColor", @"selectedMenuItemColor", @"selectedMenuItemTextColor", @"selectedTextBackgroundColor", @"selectedTextColor", @"shadowColor", @"tertiaryLabelColor", @"textBackgroundColor", @"textColor", @"windowBackgroundColor", @"windowFrameColor", @"windowFrameTextColor", @"rowBackgroundColor", @"alternateRowBackgroundColor", @"toolTipColor", @"toolTipTextColor", nil];
  unsigned errors = 0;
  for (int i = 0; i < 3; i++) {
    [GSTheme setTheme:nil];
    [GSTheme setTheme:eau];
    NSColorList *live = [NSColorList colorListNamed:@"System"];
    unsigned lost = 0, missing = 0;
    for (NSString *key in [disk allKeys])
      if (![[disk colorWithKey:key] isEqual:[live colorWithKey:key]]) lost++;
    for (NSString *key in fallback)
      if (![live colorWithKey:key]) missing++;
    fprintf(stderr, "switch=%d lost=%u missing=%u live-editable=%d\n", i+1, lost, missing, [live isEditable]);
    errors += lost + missing + ![live isEditable];
  }
  [disk release]; [eau release]; [pool drain];
  return errors ? 1 : 0;
}
