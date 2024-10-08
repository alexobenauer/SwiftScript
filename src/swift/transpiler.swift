protocol Transpiler {
  func transpile(ast: [ASTNode]) -> String
}

struct TranspilerError: Error {
    let message: String
}

struct JSTranspiler: Transpiler {
    let managedRuntime: Bool
    
    init(managedRuntime: Bool = false) {
        self.managedRuntime = managedRuntime
    }

    func transpile(ast: [ASTNode]) -> String {
        return runtime(managedRuntime: managedRuntime) + "\n\n// Compiled code\n\n" + ast.map({ transpileNode($0) }).joined(separator: "\n")
    }

    private func transpileNode(_ node: ASTNode, isInClass: Bool = false) -> String {
        switch node {
        case let node as VarDeclaration:
            return transpileVarDeclaration(node, isInClass: isInClass)
        case let node as StructDeclaration:
            return transpileStructDeclaration(node)
        case let node as ClassDeclaration:
            return transpileClassDeclaration(node)
        case let node as FunctionDeclaration:
            return transpileFunction(node)
        case let node as EnumDeclaration:
            return transpileEnumDeclaration(node, isInClass: isInClass)
        case let node as ProtocolDeclaration:
            return transpileProtocolDeclaration(node)
        case let node as TypealiasDeclaration:
            return transpileTypealias(node)
        case let node as IfStatement:
            return transpileIf(node)
        case let node as IfLetStatement:
            return transpileIfLet(node)
        case let node as GuardStatement:
            return transpileGuard(node)
        case let node as GuardLetStatement:
            return transpileGuardLet(node)
        case let node as SwitchStatement:
            return transpileSwitch(node)
        case let node as ForStatement:
            return transpileFor(node)
        case let node as WhileStatement:
            return transpileWhile(node)
        case let node as RepeatStatement:
            return transpileRepeat(node)
        case let node as ReturnStatement:
            return transpileReturn(node)
        case let node as BreakStatement:
            return transpileBreak(node)
        case let node as ContinueStatement:
            return transpileContinue(node)
        case let node as BlankStatement:
            return transpileBlank(node)
        case let node as DoCatchStatement:
            return transpileDoCatch(node)
        case let node as ThrowStatement:
            return transpileThrow(node)
        case let node as BlockStatement:
            return transpileBlock(node)
        case let node as ExpressionStatement:
            return transpileExpressionStatement(node)
        default:
            print("Transpiler error: Unknown node type: \(type(of: node))")
            return ""
        }
    }

    private func transpileVarDeclaration(_ node: VarDeclaration, isInClass: Bool = false) -> String {
        let keyword = isInClass ? "" : (node.isConstant && node.initializer != nil ? "const" : "let") // JS doesn't allow constants without initializers
        let name = transpileIdentifier(node.name.value)
        let type = transpileType(node.type)
        
        if !self.managedRuntime {
            let initializer = node.initializer != nil ? " = \(transpileExpression(node.initializer!))" : ""
            return "\(keyword) \(name)\(initializer);"
        }
        else {
            let initializer = node.initializer != nil ? transpileExpression(node.initializer!) : "null"
            return """
            \(keyword) \(name) = {
                value: \(initializer),
                type: "\(type)",\(node.isConstant ? "\nisConstant: true," : "")\(node.isPrivate ? "\nisPrivate: true," : "")\(node.initializer != nil ? "\nisUndefined: true," : "")
            };
            """
        }

        // Wrapping all variables lets us handle that JS doesn't allow constants without initializers, it lets us handle optional types, and it lets us store information about types without having to do more resolver passes
    }

    private func transpileStructDeclaration(_ node: StructDeclaration) -> String {
      // TODO: Need to adjust for JS's pass-by-reference behavior
        let name = transpileIdentifier(node.name.value)
        let inheritedTypes = node.inheritedTypes.map { $0.value }.joined(separator: ", ")
        let members = node.members.map { transpileNode($0, isInClass: true) }.joined(separator: "\n  ")
        
        var constructor = ""
        if !node.members.contains(where: { node in
            if let node = node as? FunctionDeclaration {
                return node.name.value == "init"
            }
            return false
        }) {
            constructor = "  constructor(params = {}) {\n    Object.assign(this, params);\n  }\n\n"
        }
        return "class \(name) {\n\(constructor)  \(members)\n}"
    }

    private func transpileClassDeclaration(_ node: ClassDeclaration) -> String {
        let name = transpileIdentifier(node.name.value)
        let superclass = node.inheritedTypes.first?.value ?? ""
        let properties = node.properties.map { transpileVarDeclaration($0 as! VarDeclaration, isInClass: true) }.joined(separator: "\n  ")
        let methods = node.methods.map { transpileFunction($0) }.joined(separator: "\n\n  ")
        
        return "class \(name)\(superclass.isEmpty ? "" : " extends \(superclass)") {\n  \(properties)\n\n  \(methods)\n}"
    }

    private func transpileFunction(_ node: FunctionDeclaration) -> String {
        // Function names, except for constructor, should include external names of parameters that don't have default values, e.g. "print_message"
        // But we may need to do that in the resolver

        let name = node.name.value == "init" ? "constructor" : transpileIdentifier(node.name.value)
        let params = node.parameters.count > 0 ? "params = {}" : ""
        let paramsInBody = transpileParamsIntoBody(node.parameters)
        let bodyBlock = transpileBlock(node.body)
        let body = "\(paramsInBody)\n\(bodyBlock)"

        let staticKeyword = node.isStatic ? "static " : ""
        
        return "\(staticKeyword)\(node.kind == .function ? "function " : "")\(name)(\(params)) { \(body) }"
    }

    private func transpileParamsIntoBody(_ parameters: [Parameter]) -> String {
        if parameters.count == 0 { return "" }

        let nonVariadicParams = parameters.filter({ !$0.isVariadic })
        
        let paramDestructuring = nonVariadicParams.enumerated().map { index, param in
            let externalName = param.externalName?.value ?? param.internalName.value
            let internalName = param.internalName.value
            let adjustedExternalName = externalName == "_" ? "_\(index + 1)" : externalName
            let defaultValue = param.defaultValue != nil ? " = \(transpileExpression(param.defaultValue!))" : ""
            return adjustedExternalName == internalName ? "\(internalName)\(defaultValue)" : "\(adjustedExternalName): \(internalName)\(defaultValue)"
        }.joined(separator: ", ")

        // For variadic params, we need to get all the arguments after the last non-variadic param and roll them up into an array
        var variadicParam = ""
        if parameters.last!.isVariadic {
            variadicParam = """
            const \(parameters.last!.internalName.value) = Object.entries(params)
                .map(([key, value]) => ({ key, value }))
                .filter(({ key }) => key.startsWith('_'))
                .map(({ key, value }) => ({ key, value, position: parseInt(key.split('_')[1]) }))
                .sort((a, b) => a.position - b.position)
                .filter(({ position }) => position > '\(parameters.count - 1)')
                .map(({ value }) => value);
            """
        }

        // TODO: This only supports one variadic param for now; can add support for more
        
        if nonVariadicParams.count > 0 {
            return "const { \(paramDestructuring) } = params;\n\(variadicParam)"
        }
        else {
            return variadicParam
        }
    }

    private func transpileEnumDeclaration(_ node: EnumDeclaration, isInClass: Bool = false) -> String {
        let name = transpileIdentifier(node.name.value)
        
        let cases = node.cases.map { c in
            let caseName = c.name.value
            return "\(caseName): '\(caseName)'"
        }.joined(separator: ",\n  ")

        if !managedRuntime {
            return "\(isInClass ? "static ":"const ")\(name) = Object.freeze({\n  \(cases)\n});"
        }
        else {
            return "\(isInClass ? "static ":"const ")\(name) = { type: 'enum', value: Object.freeze({\n  \(cases)\n}) };"
        }
    }

    private func transpileProtocolDeclaration(_ node: ProtocolDeclaration) -> String {
        let name = transpileIdentifier(node.name.value)
        let members = node.members.map { transpileNode($0, isInClass: true) }.joined(separator: "\n  ")
        
        return "class \(name) {\n  \(members)\n}"
    }

    private func transpileTypealias(_ node: TypealiasDeclaration) -> String {
        let name = transpileIdentifier(node.name.value)
        let value = transpileType(node.type)
        return "const \(name) = \(value);"
    }

    private func transpileIf(_ node: IfStatement) -> String {
        let condition = transpileExpression(node.condition)
        let thenBranch = transpileBlock(node.thenBranch as! BlockStatement)
        var elseBranch = ""
        if let elseBranchNode = node.elseBranch {
            elseBranch = " else { \(transpileNode(elseBranchNode)) }"
        }
        return "if (\(condition)) { \(thenBranch) }\(elseBranch)"
    }

    private func transpileIfLet(_ node: IfLetStatement) -> String {
        let name = transpileIdentifier(node.name.value)
        let value = node.value != nil ? transpileExpression(node.value!) : name
        let thenBranch = transpileBlock(node.thenBranch as! BlockStatement)
        var elseBranch = ""
        if let elseBranchNode = node.elseBranch {
            elseBranch = " else { \(transpileNode(elseBranchNode)) }"
        }
        // Must pass through isUndefinedOrNullJS rather than comparing to both, since value might be a function call, and calling it twice would have side effects
        if !managedRuntime {
            let assignment = name == value ? "" : "const \(name) = __\(name); "
            return "const __\(name) = \(value); if (!isUndefinedOrNull(__\(name))) { \(assignment)\(thenBranch) }\(elseBranch)"
        }
        else {
            // TODO: Update to match above
            let assignment = name == value ? "" : "const \(name) = { value: \(value) }; "
            return "if (!isUndefinedOrNull(\(name))) { \(assignment)\(thenBranch) }\(elseBranch)"
        }
    }

    private func transpileGuard(_ node: GuardStatement) -> String {
        let condition = transpileExpression(node.condition)
        let body = transpileBlock(node.body as! BlockStatement)
        return "if (!(\(condition))) { \(body) }"
    }

    private func transpileGuardLet(_ node: GuardLetStatement) -> String {
        let name = transpileIdentifier(node.name.value)
        let value = transpileExpression(node.value!)
        let body = transpileBlock(node.body as! BlockStatement)
        return "if (\(value) === undefined || \(value) === null) { \(body) return; } const \(name) = \(value);"
    }

    private func transpileSwitch(_ node: SwitchStatement) -> String {
        let expression = transpileExpression(node.expression)
        let cases = node.cases.map { transpileSwitchCase($0) }.joined(separator: "\n")
        let defaultCase = node.defaultCase != nil ? "default: { \(transpileBlock(BlockStatement(statements: node.defaultCase!))) }" : ""
        return "switch (\(expression)) {\n\(cases)\n\(defaultCase)\n}"
    }

    private func transpileSwitchCase(_ caseNode: SwitchCase) -> String {
        let expressions = caseNode.expressions.map { transpileExpression($0) }.joined(separator: ":\n  case ")
        let statements = caseNode.statements.map { transpileNode($0) }.joined(separator: "\n")
        return "  case \(expressions): { \n\(statements) \n break; }"
    }

    private func transpileFor(_ node: ForStatement) -> String {
        let variable = transpileIdentifier(node.variable.value)
        let body = transpileBlock(node.body as! BlockStatement)

        if let iterable = node.iterable as? BinaryRangeExpression {
            let left = transpileExpression(iterable.left)
            let right = transpileExpression(iterable.right)
            
            switch iterable.op {
            case .DOT_DOT_DOT:
                return "for (let \(variable) = \(left); \(variable) <= \(right); \(variable)++) { \(body) }"
            case .DOT_DOT_LESS:
                return "for (let \(variable) = \(left); \(variable) < \(right); \(variable)++) { \(body) }"
            default:
                let op = transpileOperator(iterable.op)
                return "\(left) \(op) \(right)"
            }
        }
        else {
            let iterable = transpileExpression(node.iterable)
            return "for (const \(variable) of \(iterable)) { \(body) }"
        }
    }

    private func transpileWhile(_ node: WhileStatement) -> String {
        let condition = transpileExpression(node.condition)
        let body = transpileBlock(node.body as! BlockStatement)
        return "while (\(condition)) { \(body) }"
    }

    private func transpileRepeat(_ node: RepeatStatement) -> String {
        let body = transpileBlock(node.body as! BlockStatement)
        let condition = transpileExpression(node.condition)
        return "do { \(body) } while (\(condition));"
    }

    private func transpileReturn(_ node: ReturnStatement) -> String {
        if let value = node.value {
            return "return \(transpileExpression(value));"
        } else {
            return "return;"
        }
    }

    private func transpileBreak(_ node: BreakStatement) -> String {
        return "break;"
    }

    private func transpileContinue(_ node: ContinueStatement) -> String {
        return "continue;"
    }

    private func transpileBlank(_ node: BlankStatement) -> String {
        return ""
    }

    private func transpileDoCatch(_ node: DoCatchStatement) -> String {
        let body = transpileBlock(node.body as! BlockStatement)
        let catchBlock = transpileBlock(node.catchBlock as! BlockStatement)
        return "try { \(body) } catch (error) { \(catchBlock) }"
    }

    private func transpileThrow(_ node: ThrowStatement) -> String {
        let expression = transpileExpression(node.expression)
        return "throw \(expression);"
    }

    private func transpileTry(_ node: TryExpression) -> String {
        let expression = transpileExpression(node.expression)
        
        if node.isOptional {
            return "tryOptional(() => \(expression))"
        }
        else if node.isForceUnwrap {
            return "tryForce(() => \(expression))"
        }
        else {
            return expression
        }
    }

    private func transpileExpressionStatement(_ node: ExpressionStatement) -> String {
        return "\(transpileExpression(node.expression));"
    }

    private func transpileExpression(_ node: ASTNode) -> String {
        switch node {
        case let node as AssignmentExpression:
            return transpileAssignment(node)
        case let node as TernaryExpression:
            return transpileTernary(node)
        case let node as BinaryExpression:
            return transpileBinary(node)
        case let node as LogicalExpression:
            return transpileLogical(node)
        case let node as UnaryExpression:
            return transpileUnary(node)
        case let node as CallExpression:
            return transpileCall(node)
        case let node as GetExpression:
            return transpileGet(node)
        case let node as IndexExpression:
            return transpileIndex(node)
        case let node as OptionalChainingExpression:
            return transpileOptionalChaining(node)
        case let node as AsExpression:
            return transpileAs(node)
        case let node as IsExpression:
            return transpileIs(node)
        case let node as TryExpression:
            return transpileTry(node)
        case let node as LiteralExpression:
            return transpileLiteral(node)
        case let node as StringLiteralExpression:
            return transpileStringLiteral(node)
        case let node as IntLiteralExpression:
            return transpileIntLiteral(node)
        case let node as DoubleLiteralExpression:
            return transpileDoubleLiteral(node)
        case let node as SelfExpression:
            return transpileSelf(node)
        case let node as VariableExpression:
            return transpileVariable(node)
        case let node as GroupingExpression:
            return transpileGrouping(node)
        case let node as ArrayLiteralExpression:
            return transpileArrayLiteral(node)
        case let node as DictionaryLiteralExpression:
            return transpileDictionaryLiteral(node)
        default:
            print("Transpiler error: Unknown expression type: \(type(of: node))")
            return ""
        }
    }

    private func transpileAssignment(_ node: AssignmentExpression) -> String {
        let target = transpileExpression(node.target)
        let value = transpileExpression(node.value)
        switch node.op {
        case .PLUS_EQUAL:
            return "\(target) += \(value)"
        case .MINUS_EQUAL:
            return "\(target) -= \(value)"
        default:
            return "\(target) = \(value)"
        }
    }
    
    private func transpileTernary(_ node: TernaryExpression) -> String {
        let condition = transpileExpression(node.condition)
        let thenBranch = transpileExpression(node.thenBranch)
        let elseBranch = transpileExpression(node.elseBranch)
        return "\(condition) ? \(thenBranch) : \(elseBranch)"
    }

    private func transpileBinary(_ node: BinaryExpression) -> String {
        let left = transpileExpression(node.left)
        let right = transpileExpression(node.right)
        let op = transpileOperator(node.op)
        return "\(left) \(op) \(right)"
    }

    private func transpileLogical(_ node: LogicalExpression) -> String {
        let left = transpileExpression(node.left)
        let right = transpileExpression(node.right)
        let op = transpileOperator(node.op)
        return "\(left) \(op) \(right)"
    }

    private func transpileUnary(_ node: UnaryExpression) -> String {
        let operand = transpileExpression(node.operand)
        let op = transpileOperator(node.op)
        return "\(op)\(operand)"
    }

    private func transpileOperator(_ op: TokenType) -> String {
        switch op {
        case .PLUS:
            return "+"
        case .MINUS:
            return "-"
        case .STAR:
            return "*"
        case .SLASH:
            return "/"
//        case .PERCENT:
//            return "%"
        case .BANG:
            return "!"
        case .BANG_EQUAL:
            return "!=="
        case .EQUAL:
            return "=="
        case .EQUAL_EQUAL:
            return "==="
        case .LESS:
            return "<"
        case .LESS_EQUAL:
            return "<="
        case .GREATER:
            return ">"
        case .GREATER_EQUAL:
            return ">="
            
        case .AMPERSAND_AMPERSAND:
            return "&&"
        case .PIPE_PIPE:
            return "||"
        case .QUESTION_QUESTION:
            return "??"

        default:
            print("Transpiler error: Unknown operator: \(op)")
            return ""
        }
    }

    private func transpileCall(_ node: CallExpression) -> String {
        var callee = transpileExpression(node.callee)
        var args = ""
        
        if node.arguments.count > 0 {
            let inner = node.arguments.enumerated().map { index, arg in
                if let label = arg.label {
                    return "\(label.value): \(transpileExpression(arg.value))"
                }
                else {
                    return "_\(index + 1): \(transpileExpression(arg.value))"
                }
            }.joined(separator: ", ")
            
            // TODO: Only do this for transpiled functions
            args = "{ \(inner) }" //node.arguments.contains(where: { $0.label != nil }) ? "{ \(args) }" : args
        }
        
        if node.isInitializer {
            if managedRuntime {
                callee = callee.hasSuffix(".value") ? String(callee.dropLast(6)) : callee
            }

            return "(new \(callee)(\(args)))"
        }
        else {
            return "\(callee)(\(args))"
        }
    }

    private func transpileGet(_ node: GetExpression) -> String {
        let object = transpileExpression(node.object)
        let property = transpileIdentifier(node.name.value)
        return "\(object).\(property)"
    }

    private func transpileIndex(_ node: IndexExpression) -> String {
        let object = transpileExpression(node.object)
        let index = transpileExpression(node.index)
        if let rangeIndex = node.index as? BinaryRangeExpression {
            return "\(object)\(transpileBinaryRangeIndex(rangeIndex))"
        } else {
            return "\(object)[\(index)]"
        }
    }

    private func transpileBinaryRangeIndex(_ node: BinaryRangeExpression) -> String {
        let left = transpileExpression(node.left)
        let right = transpileExpression(node.right)
        
        switch node.op {
        case .DOT_DOT_DOT:
            return ".slice(\(left), \(right) + 1)"
        case .DOT_DOT_LESS:
            return ".slice(\(left), \(right))"
        default:
            let op = transpileOperator(node.op)
            return "\(left) \(op) \(right)"
        }
    }

    private func transpileOptionalChaining(_ node: OptionalChainingExpression) -> String {
        let object = transpileExpression(node.object)
        return "\(object)\(node.forceUnwrap ? "" : "?.")"
    }

    private func transpileAs(_ node: AsExpression) -> String {
        // TODO: Needs to handle some kind of type wrapping, so that the check in transpileIs works.
        return transpileExpression(node.expression)
    }

    private func transpileIs(_ node: IsExpression) -> String {
        // TODO: Not sure how we want to implement this. In order to do runtime type checking, we could have a runtime type map.
        // One approach is to use the symbol table to map names to types, and then use that map in the transpiler to do the checking.
        // Returning true for now...
        let expression = transpileExpression(node.expression)
        let type = transpileType(node.type)
        return "/* TODO: \(expression) is \(type)*/ true"
    }

    private func transpileLiteral(_ node: LiteralExpression) -> String {
        if let value = node.value {
            return "\(value)"
        }
        return "null"
    }

    private func transpileStringLiteral(_ node: StringLiteralExpression) -> String {
        if node.isMultiLine {
            return "`\(node.value)`"
        }
        else {
            return "\"\(node.value)\""
        }
    }

    private func transpileIntLiteral(_ node: IntLiteralExpression) -> String {
        return "\(node.value)"
    }

    private func transpileDoubleLiteral(_ node: DoubleLiteralExpression) -> String {
        return "\(node.value)"
    }

    private func transpileArray(_ node: ArrayLiteralExpression) -> String {
        let elements = node.elements.map { transpileExpression($0) }.joined(separator: ", ")
        return "[\(elements)]"
    }

    private func transpileDictionary(_ node: DictionaryLiteralExpression) -> String {
        let pairs = node.elements.map { pair in
            let key = transpileExpression(pair.key)
            let value = transpileExpression(pair.value)
            return "\(key): \(value)"
        }.joined(separator: ", ")
        return "({ \(pairs) })"
    }

    private func transpileGrouping(_ node: GroupingExpression) -> String {
        let expression = transpileExpression(node.expression)
        return "(\(expression))"
    }

    private func transpileSelf(_ node: SelfExpression) -> String {
        return "this"
    }

    private func transpileVariable(_ node: VariableExpression) -> String {
        if !managedRuntime { 
            return "\(transpileIdentifier(node.name.value))"
        }
        else {
            return "\(transpileIdentifier(node.name.value)).value"
        }
    }

    private func transpileArrayLiteral(_ node: ArrayLiteralExpression) -> String {
        let elements = node.elements.map { transpileExpression($0) }.joined(separator: ", ")
        return "[\(elements)]"
    }

    private func transpileDictionaryLiteral(_ node: DictionaryLiteralExpression) -> String {
        let pairs = node.elements.map { pair in
            let key = transpileExpression(pair.key)
            let value = transpileExpression(pair.value)
            return "\(key): \(value)"
        }.joined(separator: ", ")
        return "({ \(pairs) })"
    }

    private func transpileType(_ type: TypeIdentifier?) -> String {
        guard let type = type else { return "any" }

        switch type {
        case .identifier(let token):
            switch token {
            case "Int", "Double", "Float":
                return "number"
            case "String", "Character":
                return "string"
            case "Bool":
                return "boolean"
            case "Any":
                return "any"
            case "Void":
                return "void"
            default:
                return token
            }
        case .array(let elementType):
            return "\(transpileType(elementType))[]"
        case .dictionary(let keyType, let valueType):
            return "{ [key: \(transpileType(keyType))]: \(transpileType(valueType)) }"
        case .optional(let baseType):
            return "\(transpileType(baseType)) | null | undefined"
        }
    }

    // identifier transpilation:
    //  mostly need to rename anything that is a reserved word in JS
    //  but also need to handle things that are capitalized in Swift but not in JS
    //  need to change nil to null
    private func transpileIdentifier(_ identifier: String) -> String {
        switch identifier {
        case "function": return "func"
        case "arguments": return "args"
        default:
            if identifier.first == "$" {
                return "arg_\(identifier.dropFirst())"
            }

            return identifier
        }
    }
    
    private func transpileBlock(_ node: BlockStatement) -> String {
        return node.statements.map { transpileNode($0) }.joined(separator: "\n")
    }
}
