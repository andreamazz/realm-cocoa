////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMProperty_Private.hpp"

#import "RLMArray.h"
#import "RLMObject.h"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

@implementation RLMProperty {
    NSString *_objcRawType;
}

@dynamic name;
@dynamic type;
@dynamic objectClassName;
@dynamic column;
@dynamic indexed;
@dynamic isPrimary;

- (instancetype)initWithName:(NSString *)name
                        type:(RLMPropertyType)type
             objectClassName:(NSString *)objectClassName
                  indexed:(BOOL)indexed {
    self = [super init];
    if (self) {
        _property.name = name.UTF8String;
        _property.type = (realm::PropertyType)type;
        if (objectClassName) {
            _property.object_type = objectClassName.UTF8String;
        }
        _property.is_indexed = indexed;
        [self setObjcCodeFromType];
        [self updateAccessors];
    }

    return self;
}

- (instancetype)initWithProperty:(realm::Property)property {
    self = [super init];
    if (self) {
        _property = property;
        [self setObjcCodeFromType];
        [self updateAccessors];
    }
    return self;
}

- (NSString *)name {
    return [NSString stringWithUTF8String:_property.name.c_str()];
}

- (RLMPropertyType)type {
    return (RLMPropertyType)_property.type;
}

- (NSString *)objectClassName {
    NSString *objectClassName = [NSString stringWithUTF8String:_property.object_type.c_str()];
    if (!objectClassName.length) {
        return nil;
    }
    return objectClassName;
}

- (NSUInteger)column {
    return _property.table_column;
}

- (BOOL)indexed {
    return _property.is_indexed;
}

- (BOOL)isPrimary {
    return _property.is_primary;
    
}
-(void)updateAccessors {
    // populate getter/setter names if generic
    NSString *name = self.name;
    if (!_getterName) {
        _getterName = name;
    }
    if (!_setterName) {
        // Objective-C setters only capitalize the first letter of the property name if it falls between 'a' and 'z'
        int asciiCode = [name characterAtIndex:0];
        BOOL shouldUppercase = asciiCode >= 'a' && asciiCode <= 'z';
        NSString *firstChar = [name substringToIndex:1];
        firstChar = shouldUppercase ? firstChar.uppercaseString : firstChar;
        _setterName = [NSString stringWithFormat:@"set%@%@:", firstChar, [name substringFromIndex:1]];
    }

    _getterSel = NSSelectorFromString(_getterName);
    _setterSel = NSSelectorFromString(_setterName);
}

-(void)setObjcCodeFromType {
    switch (self.type) {
        case RLMPropertyTypeInt:
            _objcType = 'q';
            break;
        case RLMPropertyTypeBool:
            _objcType = 'c';
            break;
        case RLMPropertyTypeDouble:
            _objcType = 'd';
            break;
        case RLMPropertyTypeFloat:
            _objcType = 'f';
            break;
        case RLMPropertyTypeAny:
        case RLMPropertyTypeArray:
        case RLMPropertyTypeData:
        case RLMPropertyTypeDate:
        case RLMPropertyTypeObject:
        case RLMPropertyTypeString:
            _objcType = '@';
            break;
    }
}

// determine RLMPropertyType from objc code - returns true if valid type was found/set
-(BOOL)setTypeFromRawType {
    const char *code = _objcRawType.UTF8String;
    _objcType = *code;    // first char of type attr

    // map to RLMPropertyType
    switch (self.objcType) {
        case 's':   // short
        case 'i':   // int
        case 'l':   // long
        case 'q':   // long long
            _property.type = realm::PropertyTypeInt;
            return YES;
        case 'f':
            _property.type = realm::PropertyTypeFloat;
            return YES;
        case 'd':
            _property.type = realm::PropertyTypeDouble;
            return YES;
        case 'c':   // BOOL is stored as char - since rlm has no char type this is ok
        case 'B':
            _property.type = realm::PropertyTypeBool;
            return YES;
        case '@': {
            static const char arrayPrefix[] = "@\"RLMArray<";
            static const int arrayPrefixLen = sizeof(arrayPrefix) - 1;

            if (code[1] == '\0') {
                // string is "@"
                _property.type = realm::PropertyTypeAny;
            }
            else if (strcmp(code, "@\"NSString\"") == 0) {
                _property.type = realm::PropertyTypeString;
            }
            else if (strcmp(code, "@\"NSDate\"") == 0) {
                _property.type = realm::PropertyTypeDate;
            }
            else if (strcmp(code, "@\"NSData\"") == 0) {
                _property.type = realm::PropertyTypeData;
            }
            else if (strncmp(code, arrayPrefix, arrayPrefixLen) == 0) {
                // get object class from type string - @"RLMArray<objectClassName>"
                _property.type = realm::PropertyTypeArray;
                _property.object_type = std::string(code + arrayPrefixLen, strlen(code + arrayPrefixLen) - 2); // drop trailing >"

                Class cls = [RLMSchema classForString:[NSString stringWithUTF8String:_property.object_type.c_str()]];
                if (!RLMIsObjectSubclass(cls)) {
                    @throw RLMException([NSString stringWithFormat:@"'%@' is not supported as an RLMArray object type. RLMArrays can only contain instances of RLMObject subclasses. See http://realm.io/docs/cocoa/#to-many for more information.", self.objectClassName]);
                }
            }
            else if (strcmp(code, "@\"NSNumber\"") == 0) {
                @throw RLMException([NSString stringWithFormat:@"'NSNumber' is not supported as an RLMObject property. Supported number types include int, long, float, double, and other primitive number types. See http://realm.io/docs/cocoa/api/Constants/RLMPropertyType.html for all supported types."]);
            }
            else if (strcmp(code, "@\"RLMArray\"") == 0) {
                @throw RLMException(@"RLMArray properties require a protocol defining the contained type - example: RLMArray<Person>");
            }
            else {
                // for objects strip the quotes and @
                NSString *className = [_objcRawType substringWithRange:NSMakeRange(2, _objcRawType.length-3)];

                // verify type
                Class cls = [RLMSchema classForString:className];
                if (!RLMIsObjectSubclass(cls)) {
                    @throw RLMException([NSString stringWithFormat:@"'%@' is not supported as an RLMObject property. All properties must be primitives, NSString, NSDate, NSData, RLMArray, or subclasses of RLMObject. See http://realm.io/docs/cocoa/api/Classes/RLMObject.html for more information.", className]);
                }

                _property.type = realm::PropertyTypeObject;
                _property.object_type = className.UTF8String;
            }
            return YES;
        }
        default:
            return NO;
    }
}

- (bool)parseObjcProperty:(objc_property_t)property {
    unsigned int count;
    objc_property_attribute_t *attrs = property_copyAttributeList(property, &count);

    bool ignore = false;
    for (size_t i = 0; i < count; ++i) {
        switch (*attrs[i].name) {
            case 'T':
                _objcRawType = @(attrs[i].value);
                break;
            case 'R':
                ignore = true;
                break;
            case 'N':
                // nonatomic
                break;
            case 'D':
                // dynamic
                break;
            case 'G':
                _getterName = @(attrs[i].value);
                break;
            case 'S':
                _setterName = @(attrs[i].value);
                break;
            default:
                break;
        }
    }
    free(attrs);

    return ignore;
}

- (instancetype)initSwiftPropertyWithName:(NSString *)name
                                  indexed:(BOOL)indexed
                                 property:(objc_property_t)property
                                 instance:(RLMObject *)obj {
    self = [super init];
    if (!self) {
        return nil;
    }

    _property.name = name.UTF8String;
    _property.is_indexed = indexed;

    if ([self parseObjcProperty:property]) {
        return nil;
    }

    // convert array types to objc variant
    if ([_objcRawType isEqualToString:@"@\"RLMArray\""]) {
        _objcRawType = [NSString stringWithFormat:@"@\"RLMArray<%@>\"", [[obj valueForKey:name] objectClassName]];
    }

    if (![self setTypeFromRawType]) {
        NSString *reason = [NSString stringWithFormat:@"Can't persist property '%@' with incompatible type. "
                            "Add to ignoredPropertyNames: method to ignore.", self.name];
        @throw RLMException(reason);
    }

    // convert type for any swift property types (which are parsed as Any)
    if (self.type == RLMPropertyTypeAny) {
        if ([[obj valueForKey:name] isKindOfClass:[NSString class]]) {
            _property.type = realm::PropertyTypeString;
        }
    }
    if (_objcType == 'c') {
        _property.type = realm::PropertyTypeInt;
    }

    // update getter/setter names
    [self updateAccessors];

    return self;
}

- (instancetype)initWithName:(NSString *)name
                     indexed:(BOOL)indexed
                    property:(objc_property_t)property
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _property.name = name.UTF8String;
    indexed = indexed;

    if ([self parseObjcProperty:property]) {
        return nil;
    }

    if (![self setTypeFromRawType]) {
        NSString *reason = [NSString stringWithFormat:@"Can't persist property '%@' with incompatible type. "
                             "Add to ignoredPropertyNames: method to ignore.", self.name];
        @throw RLMException(reason);
    }

    // update getter/setter names
    [self updateAccessors];

    return self;
}

- (instancetype)initSwiftListPropertyWithName:(NSString *)name
                                         ivar:(Ivar)ivar
                              objectClassName:(NSString *)objectClassName {
    self = [super init];
    if (!self) {
        return nil;
    }

    _property.name = name.UTF8String;
    _property.type = realm::PropertyTypeArray;
    _property.object_type = objectClassName.UTF8String;
    _objcType = 't';
    _swiftListIvar = ivar;

    // no obj-c property for generic lists, and thus no getter/setter names

    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    RLMProperty *prop = [[RLMProperty allocWithZone:zone] init];
    prop->_property = _property;
    prop->_objcType = _objcType;
    prop->_getterName = _getterName;
    prop->_setterName = _setterName;
    prop->_getterSel = _getterSel;
    prop->_setterSel = _setterSel;
    prop->_swiftListIvar = _swiftListIvar;
    
    return prop;
}

- (BOOL)isEqualToProperty:(RLMProperty *)property {
    return self.type == property.type
        && _property.is_indexed == property->_property.is_indexed
        && _property.is_primary == property->_property.is_primary
        && [self.name isEqualToString:property.name]
        && (self.objectClassName == property.objectClassName || [self.objectClassName isEqualToString:property.objectClassName]);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ {\n\ttype = %@;\n\tobjectClassName = %@;\n\tindexed = %@;\n\tisPrimary = %@;\n}", self.name, RLMTypeToString(self.type), self.objectClassName, self.indexed ? @"YES" : @"NO", self.isPrimary ? @"YES" : @"NO"];
}

@end
