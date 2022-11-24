module potcake.http.router;

import pegged.peg : ParseTree;
import std.regex : Regex;
import vibe.core.log : logDebug;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequestHandler;
import vibe.http.status : HTTPStatus;
import std.variant : Variant;

// vibe.d components that are part of potcake.http.router's public API
public import vibe.http.server : HTTPServerRequest, HTTPServerRequestDelegate, HTTPServerResponse;

class ImproperlyConfigured : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

class NoReverseMatch : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

class ConversionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
    }
}

struct IntConverter
{
    import std.conv : ConvOverflowException, to;

    enum regex = "[0-9]+";

    int toD(const string value) @safe
    {
        try {
            return to!int(value);
        } catch (ConvOverflowException e) {
            throw new ConversionException(e.msg);
        }
    }

    string toPath(int value) @safe
    {
        return to!string(value);
    }
}

mixin template StringConverterMixin()
{
    string toD(const string value) @safe
    {
        return value;
    }

    string toPath(string value) @safe
    {
        return value;
    }
}

struct StringConverter
{
    enum regex = "[^/]+";

    mixin StringConverterMixin;
}

struct SlugConverter
{
    enum regex = "[-a-zA-Z0-9_]+";

    mixin StringConverterMixin;
}

struct UUIDConverter
{
    import std.uuid : UUID;

    enum regex = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

    UUID toD(string value) @safe
    {
        return UUID(value);
    }

    string toPath(UUID value) @safe
    {
        return value.toString();
    }
}

struct URLPathConverter
{
    enum regex = ".+";

    mixin StringConverterMixin;
}

package struct PathCaptureGroup
{
    string converterPathName;
    string pathParameter;
    string rawCaptureGroup;
}

private struct ParsedPath
{
    string path;
    string regexPath;
    PathCaptureGroup[] pathCaptureGroups;
}

private alias HandlerDelegate = void delegate(HTTPServerRequest req, HTTPServerResponse res, PathCaptureGroup[] pathCaptureGroups) @safe;

alias MiddlewareDelegate = HTTPServerRequestDelegate delegate(HTTPServerRequestDelegate next) @safe;
alias MiddlewareFunction = HTTPServerRequestDelegate function(HTTPServerRequestDelegate next) @safe;
// TODO: tests for function middleware
// TODO: warn user when middleware not safe

private struct Route
{
    Regex!char pathRegex;
    HandlerDelegate handler;
    PathCaptureGroup[] pathCaptureGroups;
}

private alias ToDDelegate = Variant delegate(string value) @safe;
private alias ToPathDelegate = string delegate(Variant value) @safe;

struct PathConverterSpec
{
    string converterPathName;
    string regex;
    ToDDelegate toDDelegate;
    ToPathDelegate toPathDelegate;
}

PathConverterSpec pathConverter(PathConverterObject)(string converterPathName, PathConverterObject pathConverterObject)
{
    ToDDelegate tdd = (value) @trusted {
        return Variant(pathConverterObject.toD(value));
    };

    ToPathDelegate tud = (value) @trusted {
        import std.traits : Parameters;

        alias paramType = Parameters!(pathConverterObject.toPath)[0];
        return pathConverterObject.toPath(value.get!paramType);
    };

    return PathConverterSpec(converterPathName, pathConverterObject.regex, tdd, tud);
}

PathConverterSpec[] defaultPathConverters = [
    pathConverter("int", IntConverter()),
    pathConverter("string", StringConverter()),
    pathConverter("slug", SlugConverter()),
    pathConverter("uuid", UUIDConverter()),
    pathConverter("path", URLPathConverter())
];

alias ConverterPathName = string;
alias PathConverterRegex = string;
alias RouteName = string;

@safe final class Router : HTTPServerRequestHandler
{
    private {
        PathConverterSpec[ConverterPathName] converterMap;
        ParsedPath[RouteName] pathMap;
        Route[][HTTPMethod] routes;
        MiddlewareDelegate[] middleware;
        bool handlerNeedsUpdate = true;
        HTTPServerRequestDelegate handler;
    }

    this()
    {
        addPathConverters();
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

        HTTPServerRequestDelegate middleware(HTTPServerRequestDelegate next)
        {
            void middlewareDelegate(HTTPServerRequest req, HTTPServerResponse res)
            {
                // Do something before routing...
                next(req, res);
                // Do something after routing...
            }

            return &middlewareDelegate;
        }

        auto router = new Router;
        router.get("/hello/<name>/<int:age>/", &helloUser);
        router.addMiddleware(&middleware);
    }

    void addMiddleware(MiddlewareDelegate middleware)
    {
        this.middleware ~= middleware;
        handlerNeedsUpdate = true;
    }

    void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        if (handlerNeedsUpdate)
        {
            updateHandler();
            rehashMaps();
            handlerNeedsUpdate = false;
        }

        handler(req, res);
    }

    private void updateHandler()
    {
        handler = &routeRequest;

        foreach_reverse (ref mw; middleware)
            handler = mw(handler);
    }

    private void rehashMaps() @trusted
    {
        converterMap = converterMap.rehash();
        pathMap = pathMap.rehash();
        routes = routes.rehash();
    }

    private void routeRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        import std.regex : matchAll;

        auto methodPresent = req.method in routes;

        if (methodPresent is null)
            return ;

        foreach (route; routes[req.method])
        {
            auto matches = matchAll(req.requestURI, route.pathRegex);

            if (matches.empty())
                continue ;

            foreach (i; 0 .. route.pathRegex.namedCaptures.length)
                req.params[route.pathRegex.namedCaptures[i]] = matches.captures[route.pathRegex.namedCaptures[i]];

            route.handler(req, res, route.pathCaptureGroups);
            break ;
        }
    }

    Router any(Handler)(string path, Handler handler, string routeName=null)
    if (isValidHandler!Handler)
    {
        import std.traits : EnumMembers;

        foreach (immutable method; [EnumMembers!HTTPMethod])
            match(path, method, handler, routeName);

        return this;
    }

    Router get(Handler)(string path, Handler handler, string routeName=null)
    if (isValidHandler!Handler)
    {
        return match(path, HTTPMethod.GET, handler, routeName);
    }

    Router match(Handler)(string path, HTTPMethod method, Handler handler, string routeName=null)
    if (isValidHandler!Handler)
    {
        import std.conv : to;
        import std.format : format;
        import std.range.primitives : back;
        import std.regex : regex;
        import std.traits : isBasicType, isSomeString, moduleName, Parameters, ReturnType;
        import std.typecons : tuple;

        auto parsedPath = parsePath(path, true);

        HandlerDelegate hd = (req, res, pathCaptureGroups) @safe {
            static if (Parameters!(handler).length == 2)
                handler(req, res);
            else
            {
                enum nonReqResParamCount = Parameters!(handler).length - 2;
                assert(
                    parsedPath.pathCaptureGroups.length == nonReqResParamCount,
                    format(
                        "Path (%s) handler's non-request/response parameter count (%s) does not match path parameter count (%s)",
                        path,
                        parsedPath.pathCaptureGroups.length,
                        nonReqResParamCount
                    )
                );

                auto tailArgs = tuple!(Parameters!(handler)[2..$]);

                static foreach (i; 0 .. tailArgs.length)
                {
                    tailArgs[i] = (() @trusted => converterMap[parsedPath.pathCaptureGroups[i].converterPathName].toDDelegate(req.params.get(pathCaptureGroups[i].pathParameter)).get!(Parameters!(handler)[i + 2]))();
                }

                handler(req, res, tailArgs.expand);
            }
        };

        auto methodPresent = method in routes;

        if (methodPresent is null)
            routes[method] = [];

        routes[method] ~= Route(regex(parsedPath.regexPath, "s"), hd, parsedPath.pathCaptureGroups); // Single-line mode works hand-in-hand with $ to exclude trailing slashes when matching.

        if (!(routeName is null))
            pathMap[routeName] = parsedPath;

        logDebug("Added %s route: %s", to!string(method), routes[method].back);

        return this;
    }

    string reverse(T...)(string routeName, T pathArguments) const
    {
        import std.array : replaceFirst;
        import std.format : format;
        import std.uri : encode;
        import std.variant : Variant, VariantException;

        auto routePresent = routeName in pathMap;

        if (routePresent is null)
            throw new NoReverseMatch(format("No route registered for name '%s'", routeName));

        auto pathData = pathMap[routeName];

        if (!(pathArguments.length == pathData.pathCaptureGroups.length))
            throw new NoReverseMatch("Count of path arguments given doesn't match count for those registered");

        auto result = pathData.path[];

        string toPath(T)(T value, string converterPathName) @trusted
        {
            auto wrappedValue = Variant(value);

            try{
                return converterMap[converterPathName].toPathDelegate(wrappedValue).encode;
            } catch (VariantException e) {
                throw new ConversionException(e.msg);
            }
        }

        foreach (i, pa; pathArguments)
        {
            try {
                result = result.replaceFirst(
                    pathData.pathCaptureGroups[i].rawCaptureGroup,
                    toPath(pa, pathData.pathCaptureGroups[i].converterPathName)
                );
            } catch (ConversionException e) {
                throw new NoReverseMatch(format("Reverse not found for '%s' with '%s'", routeName, pathArguments));
            }
        }

        return result;
    }

    void addPathConverters(PathConverterSpec[] pathConverters = [])
    {
        // This method must be called before adding handlers.
        import std.array : join;

        registerPathConverters([defaultPathConverters, pathConverters].join);
    }

    private void registerPathConverters(PathConverterSpec[] pathConverters)
    {
        foreach (pathConverter; pathConverters)
        {
            converterMap[pathConverter.converterPathName] = pathConverter;
        }
    }

    private ParsedPath parsePath(string path, bool isEndpoint=false)
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

        auto peggedPath = Path(path);
        auto pathCaptureGroups = getCaptureGroups(peggedPath);

        return ParsedPath(path, getRegexPath(path, pathCaptureGroups, isEndpoint), pathCaptureGroups);
    }

    private PathCaptureGroup[] getCaptureGroups(ParseTree p)
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

    private string getRegexPath(string path, PathCaptureGroup[] captureGroups, bool isEndpoint=false)
    {
        // Django converts 'foo/<int:pk>' to '^foo\\/(?P<pk>[0-9]+)'
        import std.array : replace, replaceFirst;

        string result = ("^" ~ path[]).replace("/", r"\/");
        if (isEndpoint)
            result = result ~ "$";

        foreach (group; captureGroups)
        {
            result = result.replaceFirst(
                group.rawCaptureGroup,
                getRegexCaptureGroup(group.converterPathName, group.pathParameter)
            );
        }

        return result;
    }

    private string getRegexCaptureGroup(string converterPathName, string pathParameter)
    {
        auto converterRegistered = converterPathName in converterMap;
        if (!converterRegistered)
            throw new ImproperlyConfigured("No path converter registered for '" ~ converterPathName ~ "'.");

        return "(?P<" ~ pathParameter ~ ">" ~ converterMap[converterPathName].regex ~ ")";
    }
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
