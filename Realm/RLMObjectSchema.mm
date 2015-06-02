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

#import "RLMObjectSchema_Private.hpp"

#import "RLMArray.h"
#import "RLMListBase.h"
#import "RLMObject_Private.h"
#import "RLMProperty_Private.hpp"
#import "RLMRealm_Dynamic.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

#import <realm/group.hpp>
#import "object_store.hpp"

@implementation RLMObjectSchema {
    // table accessor optimization
    realm::TableRef _table;
}

@dynamic className;
@dynamic properties;
@dynamic primaryKeyProperty;

- (instancetype)initWithClassName:(NSString *)objectClassName objectClass:(Class)objectClass properties:(NSArray *)properties {
    self = [super init];
    if (self) {
        _objectSchema.name = objectClassName.UTF8String;
        [self setProperties:properties];

        self.objectClass = objectClass;
    }
    return self;
}

// return properties by name
-(RLMProperty *)objectForKeyedSubscript:(id <NSCopying>)key {
    NSString *name = RLMDynamicCast<NSString>(key);
    if (!name) {
        return nil;
    }

    auto property_iter = _objectSchema.property_for_name(name.UTF8String);
    if (property_iter == _objectSchema.properties.end()) {
        return nil;
    }

    return [[RLMProperty alloc] initWithProperty:*property_iter];
}

- (NSString *)className {
    return [[NSString alloc] initWithBytesNoCopy:(void *)_objectSchema.name.c_str() length:_objectSchema.name.size() encoding:NSUTF8StringEncoding freeWhenDone:NO];
}

- (NSArray *)properties {
    NSMutableArray *properties = [NSMutableArray arrayWithCapacity:_objectSchema.properties.size()];
    for (auto iter = _objectSchema.properties.begin(); iter != _objectSchema.properties.end(); iter++) {
        [properties addObject:[[RLMProperty alloc] initWithProperty:*iter]];
    }
    return properties;
}

- (void)setProperties:(NSArray *)properties {
    _objectSchema.properties.clear();
    for (RLMProperty *prop in properties) {
        std::string propName = prop.name.UTF8String;
        _objectSchema.properties.push_back(prop->_property);
    }
}

- (RLMProperty *)primaryKeyProperty {
    if (!_objectSchema.primary_key.length()) {
        return nil;
    }
    return [[RLMProperty alloc] initWithProperty:*_objectSchema.primary_key_property()];
}

+ (instancetype)schemaForObjectClass:(Class)objectClass {
    RLMObjectSchema *schema = [RLMObjectSchema new];

    // determine classname from objectclass as className method has not yet been updated
    NSString *className = NSStringFromClass(objectClass);
    bool isSwift = [RLMSwiftSupport isSwiftClassName:className];
    if (isSwift) {
        className = [RLMSwiftSupport demangleClassName:className];
    }
    schema->_objectSchema.name = className.UTF8String;
    schema.objectClass = objectClass;
    schema.accessorClass = RLMDynamicObject.class;
    schema.isSwiftClass = isSwift;

    // create array of RLMProperties, inserting properties of superclasses first
    Class cls = objectClass;
    Class superClass = class_getSuperclass(cls);
    NSArray *props = @[];
    while (superClass && superClass != RLMObjectBase.class) {
        props = [[RLMObjectSchema propertiesForClass:cls isSwift:isSwift] arrayByAddingObjectsFromArray:props];
        cls = superClass;
        superClass = class_getSuperclass(superClass);
    }
    schema.properties = props;

    // verify that we didn't add any properties twice due to inheritance
    if (props.count != [NSSet setWithArray:[props valueForKey:@"name"]].count) {
        NSCountedSet *countedPropertyNames = [NSCountedSet setWithArray:[props valueForKey:@"name"]];
        NSSet *duplicatePropertyNames = [countedPropertyNames filteredSetUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *) {
            return [countedPropertyNames countForObject:object] > 1;
        }]];

        if (duplicatePropertyNames.count == 1) {
            @throw RLMException([NSString stringWithFormat:@"Property '%@' is declared multiple times in the class hierarchy of '%@'", duplicatePropertyNames.allObjects.firstObject, className]);
        } else {
            @throw RLMException([NSString stringWithFormat:@"Object '%@' has properties that are declared multiple times in its class hierarchy: '%@'", className, [duplicatePropertyNames.allObjects componentsJoinedByString:@"', '"]]);
        }
    }

    if (NSString *primaryKey = [objectClass primaryKey]) {
        schema->_objectSchema.primary_key = primaryKey.UTF8String;
        for (RLMProperty *prop in schema.properties) {
            if ([primaryKey isEqualToString:prop.name]) {
                prop->_property.is_indexed = true;
                prop->_property.is_primary = true;
                break;
            }
        }

        if (!schema.primaryKeyProperty) {
            NSString *message = [NSString stringWithFormat:@"Primary key property '%@' does not exist on object '%@'",
                                 primaryKey, className];
            @throw RLMException(message);
        }
        if (schema.primaryKeyProperty.type != RLMPropertyTypeInt && schema.primaryKeyProperty.type != RLMPropertyTypeString) {
            @throw RLMException(@"Only 'string' and 'int' properties can be designated the primary key");
        }
    }

    return schema;
}

+ (NSArray *)propertiesForClass:(Class)objectClass isSwift:(bool)isSwiftClass {
    Class objectUtil = RLMObjectUtilClass(isSwiftClass);
    NSArray *ignoredProperties = [objectUtil ignoredPropertiesForClass:objectClass];

    // For Swift classes we need an instance of the object when parsing properties
    id swiftObjectInstance = isSwiftClass ? [[objectClass alloc] init] : nil;

    unsigned int count;
    objc_property_t *props = class_copyPropertyList(objectClass, &count);
    NSMutableArray *propArray = [NSMutableArray arrayWithCapacity:count];
    NSSet *indexed = [[NSSet alloc] initWithArray:[objectUtil indexedPropertiesForClass:objectClass]];
    for (unsigned int i = 0; i < count; i++) {
        NSString *propertyName = @(property_getName(props[i]));
        if ([ignoredProperties containsObject:propertyName]) {
            continue;
        }

        RLMProperty *prop = nil;
        if (isSwiftClass) {
            prop = [[RLMProperty alloc] initSwiftPropertyWithName:propertyName
                                                          indexed:[indexed containsObject:propertyName]
                                                         property:props[i]
                                                         instance:swiftObjectInstance];
        }
        else {
            prop = [[RLMProperty alloc] initWithName:propertyName indexed:[indexed containsObject:propertyName] property:props[i]];
        }

        if (prop) {
            [propArray addObject:prop];
         }
    }
    free(props);

    if (isSwiftClass) {
        // List<> properties don't show up as objective-C properties due to
        // being generic, so use Swift reflection to get a list of them, and
        // then access their ivars directly
        for (NSString *propName in [objectUtil getGenericListPropertyNames:swiftObjectInstance]) {
            Ivar ivar = class_getInstanceVariable(objectClass, propName.UTF8String);
            id value = object_getIvar(swiftObjectInstance, ivar);
            NSString *className = [value _rlmArray].objectClassName;
            NSUInteger existing = [propArray indexOfObjectPassingTest:^BOOL(RLMProperty *obj, __unused NSUInteger idx, __unused BOOL *stop) {
                return [obj.name isEqualToString:propName];
            }];
            if (existing != NSNotFound) {
                [propArray removeObjectAtIndex:existing];
            }
            [propArray addObject:[[RLMProperty alloc] initSwiftListPropertyWithName:propName
                                                                               ivar:ivar
                                                                    objectClassName:className]];
        }
    }

    return propArray;
}

// generate a schema from a table - specify the custom class name for the dynamic
// class and the name to be used in the schema - used for migrations and dynamic interface
+(instancetype)schemaFromTableForClassName:(NSString *)className realm:(RLMRealm *)realm {
    // create schema object and set properties
    RLMObjectSchema *schema = [RLMObjectSchema new];
    schema->_objectSchema = ObjectSchema(realm.group, className.UTF8String);

    // for dynamic schema use vanilla RLMDynamicObject accessor classes
    schema.objectClass = RLMObject.class;
    schema.accessorClass = RLMDynamicObject.class;
    schema.standaloneClass = RLMObject.class;

    return schema;
}

- (id)copyWithZone:(NSZone *)zone {
    RLMObjectSchema *schema = [[RLMObjectSchema allocWithZone:zone] init];
    schema->_objectSchema.name = _objectSchema.name;
    [schema setProperties:self.properties];

    schema->_objectClass = _objectClass;
    schema->_objectClass = _objectClass;
    schema->_accessorClass = _accessorClass;
    schema->_standaloneClass = _standaloneClass;
    schema->_isSwiftClass = _isSwiftClass;

    // _table not copied as it's realm::Group-specific
    return schema;
}

- (BOOL)isEqualToObjectSchema:(RLMObjectSchema *)objectSchema {
    NSArray *properties = self.properties;
    if (objectSchema.properties.count != properties.count) {
        return NO;
    }

    // compare ordered list of properties
    NSArray *otherProperties = objectSchema.properties;
    for (NSUInteger i = 0; i < properties.count; i++) {
        RLMProperty *p1 = properties[i], *p2 = otherProperties[i];
        if (p1.type != p2.type ||
            p1.column != p2.column ||
            p1.isPrimary != p2.isPrimary ||
            ![p1.name isEqualToString:p2.name] ||
            !(p1.objectClassName == p2.objectClassName || [p1.objectClassName isEqualToString:p2.objectClassName])) {
            return NO;
        }
    }
    return YES;
}

- (NSString *)description {
    NSMutableString *propertiesString = [NSMutableString string];
    for (RLMProperty *property in self.properties) {
        [propertiesString appendFormat:@"\t%@\n", [property.description stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"]];
    }
    return [NSString stringWithFormat:@"%@ {\n%@}", self.className, propertiesString];
}

- (realm::Table *)table {
    if (!_table) {
        _table = ObjectStore::table_for_object_type(_realm.group, _objectSchema.name);
    }
    return _table.get();
}

- (void)setTable:(realm::Table *)table {
    _table.reset(table);
}

@end
