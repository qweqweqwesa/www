#include "file_picker.h"

#include "core/config/engine.h"
#include "core/object/class_db.h"
#include "core/os/memory.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

IOSFilePicker *IOSFilePicker::singleton = nullptr;
static IOSFilePicker *file_picker_singleton = nullptr;

@interface GodotDocumentPickerDelegate : NSObject <UIDocumentPickerDelegate> {
@public
    IOSFilePicker *owner;
}
@end

static GodotDocumentPickerDelegate *document_picker_delegate = nil;

static UIViewController *godot_top_view_controller() {
    UIWindow *window = nil;
    NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        UIWindowScene *window_scene = (UIWindowScene *)scene;
        for (UIWindow *candidate in window_scene.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window == nil && window_scene.windows.count > 0) {
            window = window_scene.windows.firstObject;
        }
        if (window != nil) {
            break;
        }
    }

    if (window == nil) {
        window = [UIApplication sharedApplication].windows.firstObject;
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

@implementation GodotDocumentPickerDelegate

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (owner != nullptr) {
        owner->complete_cancelled();
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (owner == nullptr) {
        return;
    }
    if (urls.count == 0) {
        owner->complete_cancelled();
        return;
    }

    NSURL *source = urls.firstObject;
    NSString *extension = source.pathExtension.lowercaseString;
    if (![extension isEqualToString:@"zip"] && ![extension isEqualToString:@"pck"]) {
        owner->complete_error(String("ZIP 또는 PCK 파일만 선택할 수 있습니다."));
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *documents = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    if (documents == nil) {
        owner->complete_error(String("앱 Documents 폴더를 찾지 못했습니다."));
        return;
    }

    NSURL *games = [documents URLByAppendingPathComponent:@"ImportedGames" isDirectory:YES];
    NSError *error = nil;
    if (![fm createDirectoryAtURL:games withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSString *message = error.localizedDescription ?: @"게임 폴더를 만들 수 없습니다.";
        owner->complete_error(String::utf8(message.UTF8String));
        return;
    }

    NSString *filename = source.lastPathComponent;
    if (filename.length == 0) {
        filename = [NSString stringWithFormat:@"game.%@", extension];
    }
    NSURL *destination = [games URLByAppendingPathComponent:filename isDirectory:NO];

    BOOL scoped = [source startAccessingSecurityScopedResource];
    @try {
        if ([fm fileExistsAtPath:destination.path]) {
            if (![fm removeItemAtURL:destination error:&error]) {
                NSString *message = error.localizedDescription ?: @"기존 파일을 교체할 수 없습니다.";
                owner->complete_error(String::utf8(message.UTF8String));
                return;
            }
            error = nil;
        }
        if (![fm copyItemAtURL:source toURL:destination error:&error]) {
            NSString *message = error.localizedDescription ?: @"선택한 파일을 앱으로 복사할 수 없습니다.";
            owner->complete_error(String::utf8(message.UTF8String));
            return;
        }
    } @finally {
        if (scoped) {
            [source stopAccessingSecurityScopedResource];
        }
    }

    owner->complete_selected(String::utf8(destination.path.UTF8String));
}

@end

void IOSFilePicker::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open_picker"), &IOSFilePicker::open_picker);
    ClassDB::bind_method(D_METHOD("poll_result"), &IOSFilePicker::poll_result);
}

IOSFilePicker *IOSFilePicker::get_singleton() {
    return singleton;
}

IOSFilePicker::IOSFilePicker() {
    singleton = this;
    document_picker_delegate = [[GodotDocumentPickerDelegate alloc] init];
    document_picker_delegate->owner = this;
}

IOSFilePicker::~IOSFilePicker() {
    if (document_picker_delegate != nil) {
        document_picker_delegate->owner = nullptr;
        document_picker_delegate = nil;
    }
    if (singleton == this) {
        singleton = nullptr;
    }
}

Error IOSFilePicker::open_picker() {
    if (picker_open) {
        return ERR_BUSY;
    }
    picker_open = true;
    pending_status = String();
    pending_path = String();
    pending_error = String();

    IOSFilePicker *self = this;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self != IOSFilePicker::get_singleton()) {
            return;
        }
        UIViewController *root = godot_top_view_controller();
        if (root == nil) {
            self->complete_error(String("iOS 파일 선택기를 표시할 화면을 찾지 못했습니다."));
            return;
        }

        NSMutableArray<UTType *> *types = [NSMutableArray array];
        UTType *zip_type = UTTypeZIP;
        UTType *pck_type = [UTType typeWithIdentifier:@"org.godotengine.resource-pack"];
        if (zip_type != nil) {
            [types addObject:zip_type];
        }
        if (pck_type != nil) {
            [types addObject:pck_type];
        }
        if (pck_type == nil) {
            // Fallback keeps .pck selectable even if iOS has not cached our exported UTI yet.
            [types addObject:UTTypeData];
        }
        if (types.count == 0) {
            [types addObject:UTTypeData];
        }

        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        picker.delegate = document_picker_delegate;
        picker.allowsMultipleSelection = NO;
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
        [root presentViewController:picker animated:YES completion:nil];
    });

    return OK;
}

Dictionary IOSFilePicker::poll_result() {
    Dictionary result;
    if (pending_status.is_empty()) {
        return result;
    }
    result["status"] = pending_status;
    if (!pending_path.is_empty()) {
        result["path"] = pending_path;
    }
    if (!pending_error.is_empty()) {
        result["error"] = pending_error;
    }
    pending_status = String();
    pending_path = String();
    pending_error = String();
    return result;
}

void IOSFilePicker::complete_selected(const String &p_path) {
    pending_path = p_path;
    pending_error = String();
    pending_status = "selected";
    picker_open = false;
}

void IOSFilePicker::complete_cancelled() {
    pending_path = String();
    pending_error = String();
    pending_status = "cancelled";
    picker_open = false;
}

void IOSFilePicker::complete_error(const String &p_error) {
    pending_path = String();
    pending_error = p_error;
    pending_status = "error";
    picker_open = false;
}

// Godot's generated dummy.cpp declares plugin entry points as C++ functions.
void file_picker_init() {
    if (file_picker_singleton == nullptr) {
        file_picker_singleton = memnew(IOSFilePicker);
        Engine::get_singleton()->add_singleton(Engine::Singleton("IOSFilePicker", file_picker_singleton));
    }
}

void file_picker_deinit() {
    if (file_picker_singleton != nullptr) {
        memdelete(file_picker_singleton);
        file_picker_singleton = nullptr;
    }
}
