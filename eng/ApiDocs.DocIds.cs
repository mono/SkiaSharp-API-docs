using System;
using System.Collections.Generic;
using Mono.Cecil;

namespace SkiaSharp.ApiDocs;

public sealed class PublicApiDocId
{
    public string DocId { get; init; } = "";
    public string Assembly { get; init; } = "";
    public int MetadataToken { get; init; }
    public string Signature { get; init; } = "";
    public bool IsPublic { get; init; }
    public bool IsErrorObsolete { get; init; }
}

public static class PublicApiDocIdEnumerator
{
    public static IReadOnlyList<PublicApiDocId> Enumerate(string assemblyPath)
        => Enumerate(assemblyPath, false);

    public static IReadOnlyList<PublicApiDocId> EnumerateAll(string assemblyPath)
        => Enumerate(assemblyPath, true);

    public static IReadOnlyList<string> EnumerateReferencedTypes(string assemblyPath)
    {
        using var module = ModuleDefinition.ReadModule(assemblyPath, new ReaderParameters {
            ReadingMode = ReadingMode.Deferred,
            InMemory = true
        });
        var types = new HashSet<string>(StringComparer.Ordinal);
        foreach (var type in module.GetTypeReferences())
            types.Add(TypeName(type));
        var result = new List<string>();
        foreach (var type in types)
            result.Add(type);
        return result;
    }

    private static IReadOnlyList<PublicApiDocId> Enumerate(string assemblyPath, bool includeNonPublic)
    {
        using var module = ModuleDefinition.ReadModule(assemblyPath, new ReaderParameters {
            ReadingMode = ReadingMode.Deferred,
            InMemory = true
        });
        var result = new List<PublicApiDocId>();
        foreach (var type in module.Types)
            AddType(type, assemblyPath, result, includeNonPublic);
        return result;
    }

    private static void AddType(TypeDefinition type, string assembly, List<PublicApiDocId> result, bool includeNonPublic)
    {
        var typeIsPublic = IsVisible(type);
        if (!includeNonPublic && !typeIsPublic)
            return;

        Add(result, "T:" + TypeName(type), assembly, type.MetadataToken.ToInt32(), type.FullName, typeIsPublic, IsErrorObsolete(type));
        // Delegate invocation members are emitted by the compiler and cannot have
        // source XML documentation; the delegate type itself is the public API.
        if (type.BaseType?.FullName == "System.MulticastDelegate")
            return;
        foreach (var field in type.Fields)
            if ((includeNonPublic || IsVisible(field)) && !field.IsSpecialName)
                Add(result, "F:" + TypeName(type) + "." + EscapeMemberName(field.Name), assembly, field.MetadataToken.ToInt32(), field.FullName, typeIsPublic && IsVisible(field), IsErrorObsolete(field));
        foreach (var property in type.Properties)
            if (includeNonPublic || IsVisible(property))
                Add(result, "P:" + TypeName(type) + "." + EscapeMemberName(property.Name) + Parameters(property.Parameters), assembly, property.MetadataToken.ToInt32(), property.FullName, typeIsPublic && IsVisible(property), IsErrorObsolete(property));
        foreach (var @event in type.Events)
            if (includeNonPublic || IsVisible(@event))
                Add(result, "E:" + TypeName(type) + "." + EscapeMemberName(@event.Name), assembly, @event.MetadataToken.ToInt32(), @event.FullName, typeIsPublic && IsVisible(@event), IsErrorObsolete(@event));
        foreach (var method in type.Methods)
            if ((includeNonPublic || IsVisible(method)) && IsDocumentableMethod(method))
                Add(result, "M:" + TypeName(type) + "." + MethodName(method) + Parameters(method.Parameters) + Conversion(method), assembly, method.MetadataToken.ToInt32(), method.FullName, typeIsPublic && IsVisible(method), IsErrorObsolete(method));
        foreach (var method in type.Methods)
            if ((includeNonPublic || IsVisible(method)) && method.IsConstructor && !method.IsStatic)
                Add(result, "M:" + TypeName(type) + ".#ctor" + Parameters(method.Parameters), assembly, method.MetadataToken.ToInt32(), method.FullName, typeIsPublic && IsVisible(method), IsErrorObsolete(method));
        foreach (var nested in type.NestedTypes)
            AddType(nested, assembly, result, includeNonPublic);
    }

    private static bool IsVisible(TypeDefinition type)
    {
        if (type.DeclaringType != null && !IsVisible(type.DeclaringType))
            return false;
        return type.IsPublic || type.IsNestedPublic || type.IsNestedFamily || type.IsNestedFamilyOrAssembly;
    }

    private static bool IsVisible(MethodDefinition method) =>
        method.IsPublic || method.IsFamily || method.IsFamilyOrAssembly;

    private static bool IsVisible(FieldDefinition field) =>
        field.IsPublic || field.IsFamily || field.IsFamilyOrAssembly;

    private static bool IsVisible(PropertyDefinition property) =>
        property.GetMethod != null && IsVisible(property.GetMethod) ||
        property.SetMethod != null && IsVisible(property.SetMethod) ||
        HasVisible(property.OtherMethods);

    private static bool IsVisible(EventDefinition @event) =>
        @event.AddMethod != null && IsVisible(@event.AddMethod) ||
        @event.RemoveMethod != null && IsVisible(@event.RemoveMethod) ||
        @event.InvokeMethod != null && IsVisible(@event.InvokeMethod) ||
        HasVisible(@event.OtherMethods);

    private static bool IsDocumentableMethod(MethodDefinition method) =>
        !method.IsConstructor &&
        !method.IsRuntimeSpecialName &&
        !(method.IsSpecialName && (
            method.Name.StartsWith("get_", StringComparison.Ordinal) ||
            method.Name.StartsWith("set_", StringComparison.Ordinal) ||
            method.Name.StartsWith("add_", StringComparison.Ordinal) ||
            method.Name.StartsWith("remove_", StringComparison.Ordinal) ||
            method.Name.StartsWith("raise_", StringComparison.Ordinal)));

    private static bool HasVisible(IEnumerable<MethodDefinition> methods)
    {
        foreach (var method in methods)
            if (IsVisible(method))
                return true;
        return false;
    }

    private static void Add(List<PublicApiDocId> result, string id, string assembly, int token, string signature, bool isPublic, bool isErrorObsolete) =>
        result.Add(new PublicApiDocId { DocId = id, Assembly = assembly, MetadataToken = token, Signature = signature, IsPublic = isPublic, IsErrorObsolete = isErrorObsolete });

    private static bool IsErrorObsolete(ICustomAttributeProvider provider)
    {
        foreach (var attribute in provider.CustomAttributes)
        {
            if (attribute.AttributeType.FullName != "System.ObsoleteAttribute")
                continue;
            if (attribute.ConstructorArguments.Count >= 2 &&
                attribute.ConstructorArguments[1].Value is bool isError && isError)
                return true;
            foreach (var property in attribute.Properties)
                if (property.Name == "IsError" && property.Argument.Value is bool isErrorProperty && isErrorProperty)
                    return true;
        }
        return false;
    }

    private static string MethodName(MethodDefinition method) =>
        EscapeMemberName(method.Name) + (method.HasGenericParameters ? "``" + method.GenericParameters.Count : "");

    private static string EscapeMemberName(string name) => name.Replace(".", "#");

    private static string Parameters(IEnumerable<ParameterDefinition> parameters)
    {
        var values = new List<string>();
        foreach (var parameter in parameters)
            values.Add(TypeName(parameter.ParameterType));
        return values.Count == 0 ? "" : "(" + string.Join(",", values) + ")";
    }

    private static string Conversion(MethodDefinition method) =>
        method.Name is "op_Implicit" or "op_Explicit" ? "~" + TypeName(method.ReturnType) : "";

    private static string TypeName(TypeReference type)
    {
        if (type is ByReferenceType byReference) return TypeName(byReference.ElementType) + "@";
        if (type is PointerType pointer) return TypeName(pointer.ElementType) + "*";
        if (type is ArrayType array)
        {
            if (array.Rank == 1) return TypeName(array.ElementType) + "[]";
            var dimensions = new List<string>();
            for (var i = 0; i < array.Rank; i++) dimensions.Add("0:");
            return TypeName(array.ElementType) + "[" + string.Join(",", dimensions) + "]";
        }
        if (type is GenericParameter parameter)
            return (parameter.Type == GenericParameterType.Method ? "``" : "`") + parameter.Position;
        if (type is GenericInstanceType instance)
        {
            var arguments = new List<string>();
            foreach (var argument in instance.GenericArguments) arguments.Add(TypeName(argument));
            return RemoveGenericArity(TypeName(instance.ElementType)) + "{" + string.Join(",", arguments) + "}";
        }
        var prefix = type.DeclaringType == null ? type.Namespace : TypeName(type.DeclaringType);
        return string.IsNullOrEmpty(prefix) ? type.Name : prefix + "." + type.Name;
    }

    private static string RemoveGenericArity(string typeName)
    {
        var result = new System.Text.StringBuilder(typeName.Length);
        for (var index = 0; index < typeName.Length; index++)
        {
            if (typeName[index] == '`')
            {
                while (index + 1 < typeName.Length && char.IsDigit(typeName[index + 1]))
                    index++;
                continue;
            }
            result.Append(typeName[index]);
        }
        return result.ToString();
    }
}
