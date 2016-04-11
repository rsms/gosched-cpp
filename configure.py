#!/usr/bin/env python
"Script that generates the build.ninja file"

from __future__ import print_function

from optparse import OptionParser
import os
import sys
sys.path.insert(0, 'misc')
import platform_helper
import ninja_syntax

parser = OptionParser()
parser.add_option('--platform',
                  help='target platform (' +
                       '/'.join(platform_helper.platforms()) + ')',
                  choices=platform_helper.platforms())
parser.add_option('--host',
                  help='host platform (' +
                       '/'.join(platform_helper.platforms()) + ')',
                  choices=platform_helper.platforms())
parser.add_option('--debug', action='store_true',
                  help='enable debugging extras',)
parser.add_option('--force-pselect', action='store_true',
                  help='ppoll() is used by default where available, '
                       'but some platforms may need to use pselect instead',)
(options, args) = parser.parse_args()
if args:
    print('ERROR: extra unparsed command-line arguments:', args)
    sys.exit(1)

platform = platform_helper.Platform(options.platform)
if options.host:
    host = platform_helper.Platform(options.host)
else:
    host = platform

# source files
lib_src  = [
  'text', 'ast', 'readfile', 'langconst', 'istr', 'strtou64',
  'lex', 'parse',
]

# lib_src += ['os_' + platform.platform()]

# lib_h    = ['parse']
main_src = ['cox']

BUILD_FILENAME = 'build.ninja'
buildfile = open(BUILD_FILENAME, 'w')
n = ninja_syntax.Writer(buildfile)
n.comment('This file is generated by ' + os.path.basename(__file__) + '.')
n.newline()

n.variable('ninja_required_version', '1.3')
n.newline()

n.comment('The arguments passed to configure.py, for rerunning it.')
n.variable('configure_args', ' '.join(sys.argv[1:]))
env_keys = set(['CXX', 'AR', 'CFLAGS', 'LDFLAGS'])
configure_env = dict((k, os.environ[k]) for k in os.environ if k in env_keys)
if configure_env:
    config_str = ' '.join([k + '=' + configure_env[k] for k in configure_env])
    n.variable('configure_env', config_str + '$ ')
n.newline()

CXX = configure_env.get('CXX', 'g++')
objext = '.o'
if platform.is_msvc():
    CXX = 'cl'
    objext = '.obj'

def src(filename):
    return os.path.join('src', filename)
def built(filename):
    return os.path.join('$builddir', filename)
def doc(filename):
    return os.path.join('doc', filename)
def cc(name, **kwargs):
    return n.build(built(os.path.join('obj', name + objext)), 'cxx', src(name + '.c'), **kwargs)
def cxx(name, **kwargs):
    return n.build(built(os.path.join('obj', name + objext)), 'cxx', src(name + '.cc'), **kwargs)
def binary(name):
    if platform.is_windows():
        exe = name + '.exe'
        n.build(os.path.join('$builddir', 'bin', name), 'phony', exe)
        return exe
    return os.path.join('$builddir', 'bin', name)

n.variable('builddir', 'build')
n.variable('cxx', CXX)
if platform.is_msvc():
    n.variable('ar', 'link')
else:
    n.variable('ar', configure_env.get('AR', 'ar'))

if platform.is_msvc():
    cflags = ['/nologo',  # Don't print startup banner.
              '/Zi',  # Create pdb with debug info.
              '/W4',  # Highest warning level.
              '/WX',  # Warnings as errors.
              '/wd4530', '/wd4100', '/wd4706',
              '/wd4512', '/wd4800', '/wd4702', '/wd4819',
              # Disable warnings about passing "this" during initialization.
              '/wd4355',
              '/GR-',  # Disable RTTI.
              # Disable size_t -> int truncation warning.
              # We never have strings or arrays larger than 2**31.
              '/wd4267',
              '/DNOMINMAX', '/D_CRT_SECURE_NO_WARNINGS',
              '/D_VARIADIC_MAX=10']
    if platform.msvc_needs_fs():
        cflags.append('/FS')
    ldflags = ['/DEBUG', '/libpath:$builddir\lib']
    if not options.debug:
        cflags += ['/Ox', '/DNDEBUG', '/GL']
        ldflags += ['/LTCG', '/OPT:REF', '/OPT:ICF']
else:
    cflags = ['-g', '-Wall', '-Wextra',
              '-Wimplicit-fallthrough',
              # '-Wno-deprecated',
              # '-Wno-unused-parameter',
              '-std=c++1y',
              '-stdlib=libc++',
              '-fno-rtti',
              '-fvisibility=hidden', '-pipe',
              '-Wno-missing-field-initializers',
              '-Wno-unused-variable',
              '-Ideps/dist/include']
              # '-DNINJA_PYTHON="%s"' % options.with_python
    if options.debug:
        cflags += ['-D_GLIBCXX_DEBUG', '-D_GLIBCXX_DEBUG_PEDANTIC', '-DDEBUG=1']
        cflags.remove('-fno-rtti')  # Needed for above pedanticness.
    else:
        cflags += ['-O2', '-DNDEBUG']
    # TODO: Find a way to check if CXX (which might be symlink) is actually clang
    if 'clang' in os.path.basename(CXX):
        cflags += ['-fcolor-diagnostics']
    if platform.is_mingw():
        cflags += ['-D_WIN32_WINNT=0x0501']
    ldflags = ['-lc++', '-L$builddir/lib']

libs = []
# libs = ['-Ldeps/dist/lib', '-lboost_context', '-lboost_thread']

if platform.is_mingw():
    cflags.remove('-fvisibility=hidden');
    ldflags.append('-static')
elif platform.is_sunos5():
    cflags.remove('-fvisibility=hidden')
elif platform.is_msvc():
    pass
# else:
#     if options.profile == 'gmon':
#         cflags.append('-pg')
#         ldflags.append('-pg')
#     elif options.profile == 'pprof':
#         cflags.append('-fno-omit-frame-pointer')
#         libs.extend(['-Wl,--no-as-needed', '-lprofiler'])

if (platform.is_linux() or platform.is_openbsd() or platform.is_bitrig()) and \
        not options.force_pselect:
    cflags.append('-DUSE_PPOLL')

def shell_escape(str):
    """Escape str such that it's interpreted as a single argument by
    the shell."""

    # This isn't complete, but it's just enough to make NINJA_PYTHON work.
    if platform.is_windows():
      return str
    if '"' in str:
        return "'%s'" % str.replace("'", "\\'")
    return str

if 'CFLAGS' in configure_env:
    cflags.append(configure_env['CFLAGS'])
n.variable('cflags', ' '.join(shell_escape(flag) for flag in cflags))
if 'LDFLAGS' in configure_env:
    ldflags.append(configure_env['LDFLAGS'])
n.variable('ldflags', ' '.join(shell_escape(flag) for flag in ldflags))
n.newline()

if platform.is_msvc():
    n.rule('cxx',
        command='$cxx /showIncludes $cflags -c $in /Fo$out',
        description='CXX $out',
        deps='msvc')
else:
    n.rule('cxx',
        command='$cxx -MMD -MT $out -MF $out.d $cflags -c $in -o $out',
        depfile='$out.d',
        deps='gcc',
        description='CXX $out')
n.newline()

if host.is_msvc():
    n.rule('ar',
           command='lib /nologo /ltcg /out:$out $in',
           description='LIB $out')
elif host.is_mingw():
    n.rule('ar',
           command='cmd /c $ar cqs $out.tmp $in && move /Y $out.tmp $out',
           description='AR $out')
else:
    n.rule('ar',
           command='rm -f $out && $ar crs $out $in',
           description='AR $out')
n.newline()

if platform.is_msvc():
    n.rule('link',
        command='$cxx $in $libs /nologo /link $ldflags /out:$out',
        description='LINK $out')
else:
    n.rule('link',
        command='$cxx $ldflags -o $out $in $libs',
        description='LINK $out')
n.newline()



# ASM
# n.rule('asmxx', command='$cxx -x assembler-with-cpp $in | as --64 -o $out')
# actions gas32
#     cpp -x assembler-with-cpp "$(>)" | as --32 -o "$(<)"
# actions gas64
#     cpp -x assembler-with-cpp "$(>)" | as --64 -o "$(<)"
# actions gasx32
#     cpp -x assembler-with-cpp "$(>)" | as --x32 -o "$(<)"
# actions gas
#     cpp -x assembler-with-cpp "$(>)" | as -o "$(<)"
# actions armasm
#     armasm "$(>)" "$(<)"
# actions masm
#     ml /c /Fo"$(<)" "$(>)"
# actions masm64
#     ml64 /c /Fo"$(<)" "$(>)"
# n.newline()
# def asmxx(name, **kwargs):
#     return n.build(built(os.path.join('obj', name + objext)), 'cxx', src(name + '.asm'), **kwargs)

objs = []

n.comment('Core source files all build into cox library.')
for name in lib_src:
    objs += cxx(name)
# for name in lib_src_asm:
#     objs += asmxx(name)

if platform.is_windows():
    for name in []:
        objs += cxx(name)
    # if platform.is_msvc():
    #     objs += cxx('minidump-win32')
    # objs += cc('getopt')
# else:
#     objs += cxx('subprocess-posix')
if platform.is_msvc():
    cox_lib = n.build(built('lib\cox.lib'), 'ar', objs)
else:
    cox_lib = n.build(built('lib/libcox.a'), 'ar', objs)
n.newline()

if platform.is_msvc():
    libs.append('cox.lib')
else:
    libs.append('-lcox')

all_targets = []

n.comment('Main executable is library plus main() function.')
objs = []
for name in main_src:
    objs += cxx(name)
cox = n.build(binary('cox'), 'link', objs, implicit=cox_lib,
                variables=[('libs', libs)])
n.newline()
all_targets += cox

# n.comment('Tests all build into ninja_test executable.')

# variables = []
# test_cflags = cflags + ['-DGTEST_HAS_RTTI=0']
# test_ldflags = None
# test_libs = libs
# objs = []
# if options.with_gtest:
#     path = options.with_gtest

#     gtest_all_incs = '-I%s -I%s' % (path, os.path.join(path, 'include'))
#     if platform.is_msvc():
#         gtest_cflags = '/nologo /EHsc /Zi /D_VARIADIC_MAX=10 '
#         if platform.msvc_needs_fs():
#           gtest_cflags += '/FS '
#         gtest_cflags += gtest_all_incs
#     else:
#         gtest_cflags = '-fvisibility=hidden ' + gtest_all_incs
#     objs += n.build(built('gtest-all' + objext), 'cxx',
#                     os.path.join(path, 'src', 'gtest-all.cc'),
#                     variables=[('cflags', gtest_cflags)])

#     test_cflags.append('-I%s' % os.path.join(path, 'include'))
# else:
#     # Use gtest from system.
#     if platform.is_msvc():
#         test_libs.extend(['gtest_main.lib', 'gtest.lib'])
#     else:
#         test_libs.extend(['-lgtest_main', '-lgtest'])

# n.variable('test_cflags', test_cflags)
# for name in ['build_log_test',
#              'build_test',
#              'clean_test',
#              'depfile_parser_test',
#              'deps_log_test',
#              'disk_interface_test',
#              'edit_distance_test',
#              'graph_test',
#              'lexer_test',
#              'manifest_parser_test',
#              'ninja_test',
#              'state_test',
#              'subprocess_test',
#              'test',
#              'util_test']:
#     objs += cxx(name, variables=[('cflags', '$test_cflags')])
# if platform.is_windows():
#     for name in ['includes_normalize_test', 'msvc_helper_test']:
#         objs += cxx(name, variables=[('cflags', test_cflags)])

# if not platform.is_windows():
#     test_libs.append('-lpthread')
# ninja_test = n.build(binary('ninja_test'), 'link', objs, implicit=cox_lib,
#                      variables=[('ldflags', test_ldflags),
#                                 ('libs', test_libs)])
# n.newline()
# all_targets += ninja_test


# n.comment('Generate a graph using the "graph" tool.')
# n.rule('gendot',
#        command='./ninja -t graph all > $out')
# n.rule('gengraph',
#        command='dot -Tpng $in > $out')
# dot = n.build(built('graph.dot'), 'gendot', ['ninja', 'build.ninja'])
# n.build('graph.png', 'gengraph', dot)
# n.newline()


# n.comment('Generate Doxygen.')
# n.rule('doxygen',
#        command='doxygen $in',
#        description='DOXYGEN $in')
# n.variable('doxygen_mainpage_generator',
#            src('gen_doxygen_mainpage.sh'))
# n.rule('doxygen_mainpage',
#        command='$doxygen_mainpage_generator $in > $out',
#        description='DOXYGEN_MAINPAGE $out')
# mainpage = n.build(built('doxygen_mainpage'), 'doxygen_mainpage',
#                    ['README', 'COPYING'],
#                    implicit=['$doxygen_mainpage_generator'])
# n.build('doxygen', 'doxygen', doc('doxygen.config'),
#         implicit=mainpage)
# n.newline()

if not host.is_mingw():
    n.comment('Regenerate build files if build script changes.')
    n.rule('configure',
           command='${configure_env}python configure.py $configure_args',
           generator=True)
    n.build('build.ninja', 'configure',
            implicit=['configure.py', os.path.normpath('misc/ninja_syntax.py')])
    n.newline()

n.default(cox)
n.newline()

n.build('all', 'phony', all_targets)

print('wrote %s.' % BUILD_FILENAME)