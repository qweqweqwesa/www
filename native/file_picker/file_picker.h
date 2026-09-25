#ifndef IOS_FILE_PICKER_H
#define IOS_FILE_PICKER_H

#include "core/error/error_list.h"
#include "core/object/object.h"
#include "core/string/ustring.h"
#include "core/variant/dictionary.h"

class IOSFilePicker : public Object {
    GDCLASS(IOSFilePicker, Object);

    static IOSFilePicker *singleton;
    String pending_status;
    String pending_path;
    String pending_error;
    bool picker_open = false;

protected:
    static void _bind_methods();

public:
    static IOSFilePicker *get_singleton();

    Error open_picker();
    Dictionary poll_result();

    void complete_selected(const String &p_path);
    void complete_cancelled();
    void complete_error(const String &p_error);

    IOSFilePicker();
    ~IOSFilePicker();
};

#endif
