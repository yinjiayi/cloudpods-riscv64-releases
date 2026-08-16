using System.Security.Cryptography;
using Mono.Cecil;
using Mono.Cecil.Cil;

const string TypeName = "JsonTypeReflector";
const string GetterName = "get_DynamicCodeGeneration";

if (args.Length != 3)
{
    Console.Error.WriteLine(
        "usage: RunnerJsonNetCompatPatcher INPUT OUTPUT EXPECTED_INPUT_SHA256");
    return 2;
}

var input = Path.GetFullPath(args[0]);
var output = Path.GetFullPath(args[1]);
var expectedInputSha256 = args[2].ToLowerInvariant();

if (expectedInputSha256.Length != 64 ||
    expectedInputSha256.Any(character => !Uri.IsHexDigit(character)))
{
    throw new ArgumentException("EXPECTED_INPUT_SHA256 must be 64 hexadecimal characters");
}

var actualInputSha256 = HashFile(input);
if (!actualInputSha256.Equals(expectedInputSha256, StringComparison.Ordinal))
{
    throw new InvalidOperationException(
        $"input SHA-256 mismatch: expected {expectedInputSha256}, got {actualInputSha256}");
}

using var assembly = AssemblyDefinition.ReadAssembly(input, new ReaderParameters
{
    ReadSymbols = false,
    InMemory = true,
});

var originalIdentity = CaptureIdentity(assembly);
var targetTypes = assembly.MainModule.Types
    .Where(type => type.Name == TypeName &&
        type.Namespace.StartsWith("Newtonsoft.Json.", StringComparison.Ordinal))
    .ToArray();
if (targetTypes.Length != 1)
{
    throw new InvalidOperationException(
        $"expected exactly one Newtonsoft.Json.*.{TypeName}, found {targetTypes.Length}");
}
var targetType = targetTypes[0];
var candidates = targetType.Methods
    .Where(method => method.Name == GetterName)
    .ToArray();
if (candidates.Length != 1)
{
    throw new InvalidOperationException(
        $"expected exactly one {targetType.FullName}.{GetterName}, found {candidates.Length}");
}

var getter = candidates[0];
if (!getter.IsStatic || getter.HasParameters ||
    getter.ReturnType.MetadataType != MetadataType.Boolean || !getter.HasBody)
{
    throw new InvalidOperationException("target getter has an unexpected signature");
}

var originalIl = string.Join(", ", getter.Body.Instructions.Select(FormatInstruction));
if (getter.Body.Instructions.Count == 2 &&
    getter.Body.Instructions[0].OpCode == OpCodes.Ldc_I4_0 &&
    getter.Body.Instructions[1].OpCode == OpCodes.Ret)
{
    throw new InvalidOperationException("input assembly is already patched");
}

getter.Body.ExceptionHandlers.Clear();
getter.Body.Variables.Clear();
getter.Body.InitLocals = false;
getter.Body.Instructions.Clear();
getter.Body.Instructions.Add(Instruction.Create(OpCodes.Ldc_I4_0));
getter.Body.Instructions.Add(Instruction.Create(OpCodes.Ret));

Directory.CreateDirectory(Path.GetDirectoryName(output)!);
assembly.Write(output, new WriterParameters { WriteSymbols = false });

using var verificationAssembly = AssemblyDefinition.ReadAssembly(output, new ReaderParameters
{
    ReadSymbols = false,
    InMemory = true,
});
var outputIdentity = CaptureIdentity(verificationAssembly);
if (!originalIdentity.Equals(outputIdentity, StringComparison.Ordinal))
{
    throw new InvalidOperationException(
        $"assembly identity changed: {originalIdentity} -> {outputIdentity}");
}

var verificationGetter = verificationAssembly.MainModule.Types
    .SingleOrDefault(type => type.FullName == targetType.FullName)?.Methods
    .SingleOrDefault(method => method.Name == GetterName)
    ?? throw new InvalidOperationException("patched getter is missing");
if (verificationGetter.Body.Instructions.Count != 2 ||
    verificationGetter.Body.Instructions[0].OpCode != OpCodes.Ldc_I4_0 ||
    verificationGetter.Body.Instructions[1].OpCode != OpCodes.Ret)
{
    throw new InvalidOperationException("patched getter did not verify");
}

Console.WriteLine($"input_sha256={actualInputSha256}");
Console.WriteLine($"output_sha256={HashFile(output)}");
Console.WriteLine($"assembly_identity={originalIdentity}");
Console.WriteLine($"original_il={originalIl}");
Console.WriteLine("patched_il=ldc.i4.0, ret");
return 0;

static string HashFile(string path)
{
    using var stream = File.OpenRead(path);
    return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
}

static string CaptureIdentity(AssemblyDefinition assembly)
{
    var name = assembly.Name;
    var token = name.PublicKeyToken is { Length: > 0 }
        ? Convert.ToHexString(name.PublicKeyToken).ToLowerInvariant()
        : "null";
    return $"{name.Name}, Version={name.Version}, Culture={name.Culture ?? "neutral"}, PublicKeyToken={token}";
}

static string FormatInstruction(Instruction instruction)
{
    return instruction.Operand is null
        ? instruction.OpCode.Name
        : $"{instruction.OpCode.Name} {instruction.Operand}";
}
