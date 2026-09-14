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
}

public static class PublicApiDocIdEnumerator
{
    public static IReadOnlyList<PublicApiDocId> Enumerate(string assemblyPath)
    {
        using var module = ModuleDefinition.ReadModule(assemblyPath, new ReaderParameters {
            ReadingMode = ReadingMode.Deferred,
            InMemory = true
        });
        var result = new List<PublicApiDocId>();
        foreach (var type in module.Types)
            AddType(type, assemblyPath, result);
        return result;
    }

    private static void AddType(TypeDefinition type, string assembly, List<PublicApiDocId> result)
    {
        if (!IsVisible(type))
            return;

        Add(result, "T:" + TypeName(type), assembly, type.MetadataToken.ToInt32(), type.FullName);
        foreach (var field in type.Fields)
            if (IsVisible(field) && !field.IsSpecialName)
                Add(result, "F:" + TypeName(type) + "." + EscapeMemberName(field.Name), assembly, field.MetadataToken.ToInt32(), field.FullName);
        foreach (var property in type.Properties)
            if (IsVisible(property))
                Add(result, "P:" + TypeName(type) + "." + EscapeMemberName(property.Name) + Parameters(property.Parameters), assembly, property.MetadataToken.ToInt32(), property.FullName);
        foreach (var @event in type.Events)
            if (IsVisible(@event))
                Add(result, "E:" + TypeName(type) + "." + EscapeMemberName(@event.Name), assembly, @event.MetadataToken.ToInt32(), @event.FullName);
        foreach (var method in type.Methods)
            if (IsVisible(method) && !method.IsSpecialName && !method.IsRuntimeSpecialName)
                Add(result, "M:" + TypeName(type) + "." + MethodName(method) + Parameters(method.Parameters) + Conversion(method), assembly, method.MetadataToken.ToInt32(), method.FullName);
        foreach (var method in type.Methods)
            if (IsVisible(method) && method.IsConstructor && !method.IsStatic)
                Add(result, "M:" + TypeName(type) + ".#ctor" + Parameters(method.Parameters), assembly, method.MetadataToken.ToInt32(), method.FullName);
        foreach (var nested in type.NestedTypes)
            AddType(nested, assembly, result);
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

    private static bool HasVisible(IEnumerable<MethodDefinition> methods)
    {
        foreach (var method in methods)
            if (IsVisible(method))
                return true;
        return false;
    }

    private static void Add(List<PublicApiDocId> result, string id, string assembly, int token, string signature) =>
        result.Add(new PublicApiDocId { DocId = id, Assembly = assembly, MetadataToken = token, Signature = signature });

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
            return TypeName(instance.ElementType) + "{" + string.Join(",", arguments) + "}";
        }
        var prefix = type.DeclaringType == null ? type.Namespace : TypeName(type.DeclaringType);
        return string.IsNullOrEmpty(prefix) ? type.Name : prefix + "." + type.Name;
    }
}
