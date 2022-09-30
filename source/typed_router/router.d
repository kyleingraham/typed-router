module typed_router.router;

import pegged.peg : ParseTree;
import std.regex : Regex;
import vibe.core.core : runApplication;
import vibe.core.log : logDebug, LogLevel, setLogLevel;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequest, HTTPServerRequestHandler, HTTPServerResponse, HTTPServerSettings, listenHTTP;
import vibe.http.status : HTTPStatus;

class ImproperlyConfigured : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

struct IntConverter
{
    enum regex = "[0-9]+";

    int toD(const string value) @safe
    {
        import std.conv : to;

        return to!int(value);
    }
}

mixin template StringToD()
{
    string toD(const string value) @safe
    {
        return value;
    }
}

struct StringConverter
{
    enum regex = "[^/]+";

    mixin StringToD;
}

struct SlugConverter
{
    enum regex = "[-a-zA-Z0-9_]+";

    mixin StringToD;
}

struct UUIDConverter
{
    import std.uuid : UUID;

    enum regex = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

    UUID toD(const string value) @safe
    {
        return UUID(value);
    }
}

struct URLPathConverter
{
    enum regex = ".+";

    mixin StringToD;
}

struct PathCaptureGroup
{
    string converterPathName;
    string pathParameter;
    string rawCaptureGroup;
}

struct ParsedPath
{
    string regexPath;
    PathCaptureGroup[] pathCaptureGroups;
}

alias HandlerDelegate = void delegate(HTTPServerRequest req, HTTPServerResponse res, PathCaptureGroup[] pathCaptureGroups) @safe;

struct Route
{
    Regex!char pathRegex;
    HandlerDelegate handler;
    PathCaptureGroup[] pathCaptureGroups;
}

struct BoundPathConverter
{
    string moduleName;
    string objectName;
    string converterPathName;
}

struct PathConverterRef
{
    void* ptr;
}

BoundPathConverter bindPathConverter(alias pathConverter, string converterPathName)()
{
    import std.traits : moduleName;

    return BoundPathConverter(moduleName!pathConverter, __traits(identifier, pathConverter), converterPathName);
}

PathConverterRef[string] pathConverterMap(BoundPathConverter[] boundPathConverters)() @trusted
{
    mixin("PathConverterRef[string] converters;");

    static foreach_reverse (boundPathConverter; boundPathConverters)
    {
        mixin("import " ~ boundPathConverter.moduleName ~ " : " ~ boundPathConverter.objectName ~ ";");
        mixin("converters[\"" ~ boundPathConverter.converterPathName ~ "\"] = PathConverterRef(cast(void*) new " ~ boundPathConverter.objectName ~ ");");
    }

    return mixin("converters");
}

template TypedURLRouter(BoundPathConverter[] userPathConverters = [])
{
    import std.array : join;

    enum boundPathConverters = [
        userPathConverters, [
            bindPathConverter!(IntConverter, "int"),
            bindPathConverter!(StringConverter, "string"),
            bindPathConverter!(SlugConverter, "slug"),
            bindPathConverter!(UUIDConverter, "uuid"),
            bindPathConverter!(URLPathConverter, "path"),
        ]
    ].join;

    ParsedPath parsePath(string path, bool isEndpoint=false)()
    {
        import pegged.grammar;

        // Regex can be compiled at compile-time but can't be used. pegged to the rescue.
        mixin(grammar(`
Path:
    PathCaptureGroups   <- ((;UrlChars PathCaptureGroup?) / (PathCaptureGroup ;UrlChars) / (PathCaptureGroup ;endOfInput))*
    UrlChars            <- [A-Za-z0-9-._~/]+
    PathCaptureGroup    <- '<' (ConverterPathName ':')? PathParameter '>'
    ConverterPathName   <- identifier
    PathParameter       <- identifier
`));

        enum peggedPath = Path(path);
        enum pathCaptureGroups = getCaptureGroups(peggedPath);

        return ParsedPath(getRegexPath!(path, pathCaptureGroups, isEndpoint), pathCaptureGroups);
    }

    PathCaptureGroup[] getCaptureGroups(ParseTree p)
    {
        PathCaptureGroup[] walkForGroups(ParseTree p)
        {
            import std.array : join;

            switch (p.name)
            {
                case "Path":
                return walkForGroups(p.children[0]);

                case "Path.PathCaptureGroups":
                PathCaptureGroup[] result = [];
                foreach (child; p.children)
                    result ~= walkForGroups(child);

                return result;

                case "Path.PathCaptureGroup":
                if (p.children.length == 1)
                // No path converter specified so we default to 'string'
                    return [PathCaptureGroup("string", p[0].matches[0], p.matches.join)];

                else return [PathCaptureGroup(p[0].matches[0], p[1].matches[0], p.matches.join)];

                default:
                assert(false);
            }
        }

        return walkForGroups(p);
    }

    string getRegexPath(string path, PathCaptureGroup[] captureGroups, bool isEndpoint=false)()
    {
        // Django converts 'foo/<int:pk>' to '^foo\\/(?P<pk>[0-9]+)'
        import std.array : replace, replaceFirst;

        string result = ("^" ~ path[]).replace("/", r"\/");
        if (isEndpoint)
            result = result ~ "$";

        static foreach (group; captureGroups)
        {
            result = result.replaceFirst(group.rawCaptureGroup, getRegexCaptureGroup!(group.converterPathName, group.pathParameter));
        }

        return result;
    }

    string getRegexCaptureGroup(string converterPathName, string pathParameter)()
    {
        mixin("import " ~ getBoundPathConverter!(converterPathName).moduleName ~ " : " ~ getBoundPathConverter!(converterPathName).objectName ~ ";");
        return "(?P<" ~ pathParameter ~ ">" ~ mixin(getBoundPathConverter!(converterPathName).objectName ~ ".regex") ~ ")";
    }

    BoundPathConverter getBoundPathConverter(string pathName)()
    {
        foreach (boundPathConverter; boundPathConverters)
        {
            if (boundPathConverter.converterPathName == pathName)
                return boundPathConverter;
        }

        throw new ImproperlyConfigured("No PathConverter found for converter path name '" ~ pathName ~ "'");
    }

    final class TypedURLRouter : HTTPServerRequestHandler
    {
        private {
            Route[][HTTPMethod] routes;
            PathConverterRef[string] pathConverters;
        }

        this()
        {
            pathConverters = pathConverterMap!boundPathConverters;
        }

        unittest
        {
            void helloUser(HTTPServerRequest req, HTTPServerResponse res, string name, int age) @safe
            {
                import std.conv : to;

                res.contentType = "text/html; charset=UTF-8";
                res.writeBody(`
<!DOCTYPE html>
<html lang="en">
    <head></head>
    <body>
        Hello, ` ~ name ~ `. You are ` ~ to!string(age) ~ ` years old.
    </body>
</html>`,
                HTTPStatus.ok);
            }

            auto router = new TypedURLRouter!();
            router.get!"/hello/<name>/<int:age>/"(&helloUser);
        }

        void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
        {
            import std.regex : matchAll;

            foreach (route; routes[req.method])
            {
                auto matches = matchAll(req.path, route.pathRegex);

                if (matches.empty())
                    continue ;

                foreach (i; 0 .. route.pathRegex.namedCaptures.length)
                {
                    req.params[route.pathRegex.namedCaptures[i]] = matches.captures[route.pathRegex.namedCaptures[i]];
                }

                route.handler(req, res, route.pathCaptureGroups);
                break ;
            }
        }

        TypedURLRouter get(string path, Handler)(Handler handler)
        if (isValidHandler!Handler)
        {
            return match!path(HTTPMethod.GET, handler);
        }

        TypedURLRouter match(string path, Handler)(HTTPMethod method, Handler handler)
        if (isValidHandler!Handler)
        {
            import std.conv : to;
            import std.format : format;
            import std.range.primitives : back;
            import std.regex : regex;
            import std.traits : Parameters;
            import std.typecons : tuple;

            enum parsedPath = parsePath!(path, true);

            HandlerDelegate handlerDelegate = (req, res, pathCaptureGroups) @trusted {
                static if (Parameters!(handler).length == 2)
                    handler(req, res);
                else
                {
                    enum nonReqResParamCount = Parameters!(handler).length - 2;

                    static assert(parsedPath.pathCaptureGroups.length == nonReqResParamCount, format("Path (%s) handler's non-request/response parameter count (%s) does not match path parameter count (%s)", path, parsedPath.pathCaptureGroups.length, nonReqResParamCount));

                    auto tailArgs = tuple!(Parameters!(handler)[2..$]);

                    static foreach (i; 0 .. tailArgs.length)
                    {
                        tailArgs[i] = (cast(mixin(getBoundPathConverter!(parsedPath.pathCaptureGroups[i].converterPathName).objectName ~ "*")) pathConverters[pathCaptureGroups[i].converterPathName].ptr).toD(req.params.get(pathCaptureGroups[i].pathParameter));
                    }

                    handler(req, res, tailArgs.expand);
                }
            };

            auto methodPresent = method in routes;

            if (methodPresent is null)
                routes[method] = [];

            routes[method] ~= Route(regex(parsedPath.regexPath, "s"), handlerDelegate, parsedPath.pathCaptureGroups); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.

            logDebug("Added %s route: %s", to!string(method), routes[method].back);

            return this;
        }

        template isValidHandler(Handler)
        {
            import std.traits : Parameters, ReturnType;

            static if (
                2 <= Parameters!(Handler).length &&
                is(Parameters!(Handler)[0] : HTTPServerRequest) &&
                is(Parameters!(Handler)[1] : HTTPServerResponse) &&
                is(ReturnType!Handler : void)
            )
            {
                enum isValidHandler = true;
            }
            else
            {
                enum isValidHandler = false;
            }
        }

        unittest
        {
            // Do we block invalid handlers?
            void handler(HTTPServerRequest req, HTTPServerResponse res) {}

            class HandlerClass
            {
                void handler(HTTPServerRequest req, HTTPServerResponse res) {}
            }

            void typedHandler(HTTPServerRequest req, HTTPServerResponse res, int value) {}

            void test(Handler)(Handler handler)
            {
                static assert(isValidHandler!Handler);
            }

            test(&handler);
            test(&(HandlerClass.handler));
            test(&typedHandler);
            static assert(!isValidHandler!(void function(int value)));
            static assert(!isValidHandler!(void function(HTTPServerRequest req)));
            static assert(!isValidHandler!(void function(HTTPServerResponse res)));
            static assert(!isValidHandler!(int function(HTTPServerResponse res, HTTPServerResponse res)));
        }
    }
}

private struct TestStringConverter
{
    enum regex = "[^/]+";

    string toD(const string value) @safe
    {
        return "PASS";
    }
}

unittest
{
    // Do we prioritize user path converters that override built-ins?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    void testHandler(HTTPServerRequest req, HTTPServerResponse res, string name)
    {
        assert(name == "PASS", "Used built-in 'string' path converter instead of user-supplied converter");
    }

    auto router = new TypedURLRouter!([bindPathConverter!(TestStringConverter, "string")]);
    router.get!"/hello/<string:name>/"(&testHandler);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/hello/FAIL/")), res);
}

unittest
{
    // Do we match against URLs with:
    //  - multiple path converters
    //  - one path converter
    //  - no path converters
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "A";
    }
    void b(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "B";
    }
    void c(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "C";
    }
    void d(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "D";
    }

    auto router = new TypedURLRouter!();
    router.get!"/make/<string:model>/model/<int:make>/"(&a);
    router.get!"/<int:value>/"(&b);
    router.get!"/<int:value>"(&c);
    router.get!"/no/path/converters/"(&d);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/")), res);
    assert(result == "", "Matched for non-existent '/' path");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/911/")), res);
    assert(result == "A", "Did not match GET with multiple path converter types");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/taycan/")), res);
    assert(result == "A", "Did not block GET match on 'int' type");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1/")), res);
    assert(result == "AB", "Did not match trailing '/'");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1")), res);
    assert(result == "ABC", "Did not match without trailing '/'");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/no/path/converters/")), res);
    assert(result == "ABCD", "Did not match when no path converters present");
}

unittest
{
    // Do we set 'string' as the default path converter when non is specified?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/make/<string:model>/model/<make>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/911/")), res);
    assert(result == "A", "Did not set path converter to 'string' when no type specified");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/make/porsche/model/taycan/")), res);
    assert(result == "AA", "Did not match against string using default 'string' converter");
}

unittest
{
    // Do we save path values to request.params and convert them for use when calling handlers?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        assert(req.params["id"] == "123456", "Did not save path value to request params");
    }

    void b(HTTPServerRequest req, HTTPServerResponse res, int id)
    {
        assert(req.params["id"] == "123456", "Did not save path value to request params");
        assert(id == 123456, "Did pass path value to handler");
    }

    auto router = new TypedURLRouter!();
    router.get!"/a/<int:id>/"(&a);
    router.get!"/b/<int:id>/"(&b);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/a/123456/")), res);
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/b/123456/")), res);
}

unittest
{
    // IntConverter
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, int value)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<int:value>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1/")), res);
    assert(result == "A", "Did not match 'int' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/one/")), res);
    assert(result == "A", "Matched with non-integer value");
}

unittest
{
    // SlugConverter
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, string slug)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<slug:value>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/slug-string/")), res);
    assert(result == "A", "Did not match 'slug' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/non~slug~string/")), res);
    assert(result == "A", "Matched with non-slug value");
}

unittest
{
    // UUIDConverter
    import std.uuid : UUID;
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, UUID value)
    {
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<uuid:value>/"(&a);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1234abcd-1234-abcd-1234-abcd1234abcd/")), res);
    assert(result == "A", "Did not match 'uuid' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/1234ABCD-1234-ABCD-1234-ABCD1234ABCD/")), res);
    assert(result == "A", "Matched with non-uuid value");
}

unittest
{
    // StringConverter & URLPathConverter
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res, string value)
    {
        result ~= "B";
    }

    void b(HTTPServerRequest req, HTTPServerResponse res, string value)
    {
        import std.format : format;

        string expectedValue = "some/valid/path";
        assert(value == expectedValue, format("Path not parsed correctly. Expected '%s' but got '%s'.", expectedValue, value));
        result ~= "A";
    }

    auto router = new TypedURLRouter!();
    router.get!"/<string:value>/"(&a);
    router.get!"/<path:value>/"(&b);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/some/valid/path/")), res);
    assert(result == "A", "Did not match 'path' path converter");
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/some-valid-path/")), res);
    assert(result == "AB", "Did not match with 'string' path converter");
}

unittest
{
    // Do we stop calling handlers after calling the first-matched handler?
    import vibe.http.server : createTestHTTPServerRequest, createTestHTTPServerResponse;
    import vibe.inet.url : URL;

    string result;

    void a(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "A";
    }

    void b(HTTPServerRequest req, HTTPServerResponse res)
    {
        result ~= "B";
    }


    auto router = new TypedURLRouter!();
    router.get!"/<string:value>/"(&a);
    router.get!"/<string:value>/"(&b);

    auto res = createTestHTTPServerResponse();
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/value/")), res);
    assert(result == "A", "Called additional handler after first-matched handler");
}
