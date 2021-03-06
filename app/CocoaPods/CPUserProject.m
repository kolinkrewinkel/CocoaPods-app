#import "CPUserProject.h"

#import <Fragaria/Fragaria.h>
#import <ANSIEscapeHelper/AMR_ANSIEscapeHelper.h>

#import <objc/runtime.h>

#import "CPANSIEscapeHelper.h" 

// Hack SMLTextView to also consider the leading colon when completing words, which are all the
// symbols that we support.
//

@implementation SMLTextView (CPIncludeLeadingColonsInCompletions)

+ (void)load;
{
  Method m1 = class_getInstanceMethod(self, @selector(rangeForUserCompletion));
  Method m2 = class_getInstanceMethod(self, @selector(CP_rangeForUserCompletion));
  method_exchangeImplementations(m1, m2);
}

-(NSRange)CP_rangeForUserCompletion;
{
  NSRange range = [self CP_rangeForUserCompletion];
  if (range.location != NSNotFound && range.location > 0
      && [self.string characterAtIndex:range.location-1] == ':') {
    range = NSMakeRange(range.location-1, range.length+1);
  }
  return range;
}

@end

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 1090
enum {
   NSModalResponseStop                 = (-1000),
   NSModalResponseAbort                = (-1001),
   NSModalResponseContinue             = (-1002),
};
typedef NSInteger NSModalResponse;
#endif

@interface CPUserProject () <NSTextViewDelegate>

// Such sin.
// TODO: Add real custom window controllers.
@property (strong) IBOutlet NSWindow *progressWindow;
@property (assign) IBOutlet NSTextView *progressOutputView;

@property (strong) IBOutlet MGSFragariaView *editor;
@property (strong) NSString *contents;
@property (strong) NSTask *task;
@property (strong) NSAttributedString *taskOutput;
@end

@implementation CPUserProject

- (NSString *)windowNibName;
{
  return @"CPUserProject";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)controller;
{
  [super windowControllerDidLoadNib:controller];

  self.editor.syntaxColoured = YES;
  self.editor.syntaxDefinitionName = @"Podfile";
  self.editor.string = self.contents;

  self.undoManager = self.editor.textView.undoManager;
}

- (void)textDidChange:(NSNotification *)notification;
{
  NSTextView *textView = notification.object;
  NSString *contents = textView.string;
  self.contents = contents;
}

#pragma mark - Persistance

- (BOOL)readFromURL:(NSURL *)absoluteURL
             ofType:(NSString *)typeName
              error:(NSError **)outError;
{
  if ([[absoluteURL lastPathComponent] isEqualToString:@"Podfile"]) {
    self.contents = [NSString stringWithContentsOfURL:absoluteURL
                                             encoding:NSUTF8StringEncoding
                                                error:outError];
    if (self.contents != nil) {
      return YES;
    }
  }
  return NO;
}

- (BOOL)writeToURL:(NSURL *)absoluteURL
            ofType:(NSString *)typeName
             error:(NSError **)outError;
{
  return [self.contents writeToURL:absoluteURL
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:outError];
}

#pragma mark - Progress sheet

+ (NSSet *)keyPathsForValuesAffectingProgressButtonTitle;
{
  return [NSSet setWithObject:@"task"];
}

- (NSString *)progressButtonTitle;
{
  return self.task == nil ? @"Done" : @"Cancel";
}

- (void)presentProgressSheet;
{
  NSWindowController *controller = self.windowControllers[0];
  [controller.window beginSheet:self.progressWindow completionHandler:nil];
}
- (IBAction)dismissProgressSheet:(id)sender;
{
  if (self.task.isRunning) {
    [self.task interrupt];
  }
  
  [NSApp endSheet:self.progressWindow returnCode:NSModalResponseStop];

  [self.progressWindow orderOut:self];
  // Reset the sheet /after/ it has been removed from screen.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self resetSheet];
  });

}

- (void)resetSheet;
{
  self.taskOutput = nil;
}

#pragma mark - Command execution

- (IBAction)updatePods:(id)sender;
{
  [self executeTaskWithCommand:@"update"];
}

- (IBAction)installPods:(id)sender;
{
  [self executeTaskWithCommand:@"install"];
}

- (void)executeTaskWithCommand:(NSString *)command;
{
  if (self.isDocumentEdited) {
    [self saveDocument:nil];
  }

  NSDictionary *environment = @{
    @"HOME": NSHomeDirectory(),
    @"LANG": @"en_GB.UTF-8",
    @"TERM": @"xterm-256color"
  };

  NSString *workingDirectory = [[self.fileURL URLByDeletingLastPathComponent] path];
  NSString *launchPath = @"/bin/sh";
  NSString *envBundleScript = [[NSBundle mainBundle] pathForResource:@"bundle-env"
                                                              ofType:nil
                                                        inDirectory:@"bundle/bin"];

  NSArray *arguments = @[envBundleScript, @"pod", command, @"--ansi"];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"CPShowVerboseCommandOutput"]) {
    arguments = [arguments arrayByAddingObject:@"--verbose"];
  }

#ifdef DEBUG
  NSString *args = [arguments componentsJoinedByString:@" "];
  NSLog(@"$ cd '%@' && env HOME='%@' LANG='%@' TERM='%@' %@ %@", workingDirectory,
                                                                 environment[@"HOME"],
                                                                 environment[@"LANG"],
                                                                 environment[@"TERM"],
                                                                 launchPath,
                                                                 args);
#endif

  self.task = [NSTask new];
  self.task.launchPath = launchPath;
  self.task.arguments = arguments;
  self.task.environment = environment;
  self.task.currentDirectoryPath = workingDirectory;

  NSPipe *outputPipe = [NSPipe pipe];
  self.task.standardOutput = outputPipe;
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(outputAvailable:)
                                               name:NSFileHandleDataAvailableNotification
                                             object:[outputPipe fileHandleForReading]];
  [[outputPipe fileHandleForReading] waitForDataInBackgroundAndNotify];

  NSPipe *errorPipe = [NSPipe pipe];
  self.task.standardError = errorPipe;
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(outputAvailable:)
                                               name:NSFileHandleDataAvailableNotification
                                             object:[errorPipe fileHandleForReading]];
  [[errorPipe fileHandleForReading] waitForDataInBackgroundAndNotify];

  [self.task launch];
  [self presentProgressSheet];
}

#pragma mark - Command output

// Not doing anything differently with stdout vs stderr atm.
- (void)outputAvailable:(NSNotification *)notification;
{
  NSFileHandle *fileHandle = notification.object;
  NSData *data = fileHandle.availableData;

  if (data.length > 0) {
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self appendTaskOutput:output];
  }

  if (self.task.isRunning) {
    [fileHandle waitForDataInBackgroundAndNotify];
  } else {
    [self taskDidFinish];
  }
}

- (void)taskDidFinish;
{
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:NSFileHandleDataAvailableNotification
                                                object:nil];

  NSUserNotification *completionNotification = [[NSUserNotification alloc] init];
  completionNotification.title = NSLocalizedString(@"WORKSPACE_GENERATED_NOTIFICATION_TITLE", nil);
  completionNotification.subtitle = [[self.fileURL relativePath] stringByAbbreviatingWithTildeInPath];
  [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:completionNotification];
  
  // Setting to `nil` signals through bindings that task has finished.
  self.task = nil;
}

static NSAttributedString *
ANSIUnescapeString(NSString *input) {
  static CPANSIEscapeHelper *cpANSIEscapeHelper = nil;
  static dispatch_once_t onceToken = 0;
  dispatch_once(&onceToken, ^{
    // Re-use the font that the text editor is configured to use.
    cpANSIEscapeHelper = [[CPANSIEscapeHelper alloc] init];
  });
  return [cpANSIEscapeHelper attributedStringWithANSIEscapedString:input];
}

- (void)appendTaskOutput:(NSString *)rawOutput;
{
  // Determine if we're at the tail of the output log (and should scroll) before we append more to it.
  CGRect visibleRect = self.progressOutputView.enclosingScrollView.documentVisibleRect;
  CGFloat maxContentOffset = self.progressOutputView.bounds.size.height - visibleRect.size.height;
  BOOL scrolledToBottom = visibleRect.origin.y == maxContentOffset;

  NSAttributedString *attributedOutput = ANSIUnescapeString(rawOutput);
  if (self.taskOutput) {
    NSMutableAttributedString *existingOutput = [self.taskOutput mutableCopy];
    [existingOutput appendAttributedString:attributedOutput];
    self.taskOutput = [existingOutput copy];
  } else {
    self.taskOutput = attributedOutput;
  }

  // Keep the text view at the bottom if it was previously, otherwise restore the previous position.
  if (scrolledToBottom) {
    [self.progressOutputView scrollToEndOfDocument:self];
  } else {
    [self.progressOutputView scrollPoint:visibleRect.origin];
  }
}

@end
