#!/usr/bin/ruby

require 'json'
require 'shellwords'
require 'terminfo'


LOG_PATH = '/tmp/lants-output'
ERR_PATH = '/tmp/lants-errors'


def fname_friendly(str)
    str.gsub('/', '__').gsub(/[^\w-]/, '_')
end

def job_fname(host, job)
    fname_friendly(host + '-' + job.short_name.gsub(/^\//, ''))
end

def job_log_path(host, job)
    LOG_PATH + '/' + job_fname(host, job)
end

def job_err_path(host, job)
    ERR_PATH + '/' + job_fname(host, job)
end

def pad(str, width)
    if str.length < width
        return '%-*s' % [width, str]
    elsif str.length > width
        split_m = str.match(/^( *)(.*)$/)

        spaces = split_m[1]
        text = split_m[2]

        text_w = width - spaces.length
        if text_w < 5
            if width < 5
                text_w = width
            else
                text_w = 5
            end
        end
        if text_w >= text.length
            if text.length == 0
                return ' ' * width
            else
                text_w = text.length
            end
        end

        space_w = width - text_w

        return spaces[0..(space_w-1)] + '…' + text[-(text_w-1)..-1]
    else
        return str
    end
end


class Job
    def initialize(name)
        @name = name
        @path = nil
        @short_name = nil
        @dependencies = []
        @soft_dependencies = []
        @arguments = []
        @workdir = '/tmp'
        @execute = []
        @variable_jobs = false
        @threads = '$__jobs'
        @machine = 'localhost'
        @failcount = 0
    end

    def dependencies
        @dependencies
    end

    def soft_dependencies
        @soft_dependencies
    end

    def from(desc)
        @dependencies = desc['depends'] if desc['depends']
        @soft_dependencies = desc['after'] if desc['after']
        @arguments = desc['arguments'] if desc['arguments']
        @workdir = desc['workdir'] if desc['workdir']
        @execute = desc['execute'] if desc['execute']
        @variable_jobs = desc['variable_jobs'] if desc['variable_jobs']
        @threads = desc['threads'] if desc['threads']
        @machine = desc['machine'] if desc['machine']
        @failcount = desc['failcount'] if desc['failcount']

        bad_arg = @arguments.find { |a| !(a =~ /^\w+$/) }
        if bad_arg
            raise 'Not a valid argument: ' + bad_arg
        end

        if @threads.kind_of?(Integer)
            if @threads < 0
                raise ':threads must be a non-negative integer or "$__jobs"'
            end
        elsif !(@threads =~ /^\$__jobs(:\S+)?$/)
            raise ':threads must be a non-negative integer or "$__jobs"'
        end

        if @threads.to_s.start_with?('$__jobs') && !@variable_jobs
            if @execute.empty?
                @threads = 0
            else
                @threads = 1
            end
        end

        self.expand_dependencies

        @machine = self.expand_params(@machine)
    end

    def expand_dependency(dep)
        if dep.start_with?('/')
            dep += '.json' unless File.exist?($rcwd + dep)
            dep = File.realpath($rcwd + dep)
        else
            dep += '.json' unless File.exist?(@path + '/' + dep)
            dep = File.realpath(@path + '/' + dep)
        end
        if File.directory?(dep)
            dep += '/all.json'
        end

        return dep
    end

    def expand_dependencies
        @dependencies.map! do |dep|
            self.expand_dependency(dep)
        end
        @soft_dependencies.map! do |dep|
            self.expand_dependency(dep)
        end
    end

    def expand_params(str, shellescape=false, jobs=nil)
        if @arguments.find { |a| $params[a].include?('$') }
            raise 'FIXME: $ in parameters not supported yet'
        end

        args = Hash[@arguments.map { |a| [a, $params[a]] }]
        args['__jobs'] = jobs.to_s if jobs
        args['__fname'] = job_fname(@machine, self)

        if shellescape
            args = Hash[args.map { |a, v| [a, v.shellescape] }]
        end

        nstr = ''
        i = 0

        while true
            old_i = i
            i = str.index('$', old_i)
            if !i
                nstr += str[old_i..-1]
                break
            end

            nstr += str[old_i..(i-1)] if i > old_i
            if str[i + 1] == '$'
                nstr += '$'
                i += 2
                next
            end

            i += 1
            spec = /(\w*)(:<=\d+)?/.match(str[i..-1])
            name = spec[1]
            limit = spec[2]

            val = args[name]
            raise 'Unknown variable: ' + name if !val

            if limit
                if limit.start_with?(':<=')
                    begin
                        ival = Integer(val)
                        mval = Integer(limit[3..-1])
                    rescue Exception => e
                        raise "Cannot limit #{name} by #{limit}: #{e.inspect}"
                    end

                    ival = mval if ival > mval
                    val = ival.to_s
                end
            end

            nstr += val
            i += spec[0].length
        end

        return nstr
    end

    def path
        @path
    end

    def path=(path)
        @path = path
    end

    def name
        @name
    end

    def short_name
        @short_name
    end

    def short_name=(sn)
        @short_name = sn
    end

    def threads
        @threads
    end

    def machine
        @machine
    end

    def execute
        @execute
    end

    def workdir
        @workdir
    end

    def arguments
        @arguments
    end

    def variable_jobs
        @variable_jobs
    end

    def failcount
        @failcount
    end

    def failcount=(fc)
        @failcount = fc
    end
end


class Machine
    def initialize(host)
        @host = host

        @cores = self.exec('cat /proc/cpuinfo | grep "^process" | wc -l').to_i
        if !@cores.kind_of?(Integer) || @cores <= 0
            @cores = 1
        end

        @usage = 0

        @running = {}
    end

    def local?
        @host == 'localhost'
    end

    def exec(cmd)
        if self.local?
            `#{cmd}`
        else
            `ssh #{@host} #{cmd.shellescape} < /dev/null`
        end
    end

    def execute_job(job, jobs=1)
        execution =
            ['cd ' + job.expand_params(job.workdir, false, jobs).shellescape] +
            job.execute.map { |l| job.expand_params(l, true, jobs) }

        pid = fork
        if !pid
            line = ([execution[0]] +
                    execution[1..-1].map { |c| '(' + c + ')' }) * ' && '

            if self.local?
                line = "(#{line}) &> #{job_log_path(@host, job).shellescape}"
                Kernel.exec('sh', '-c', line)
                exit 1
            else
                line = 'ssh ' + @host.shellescape + ' ' + line.shellescape
                line += ' < /dev/null'
                line += ' &> ' + job_log_path(@host, job).shellescape
                Kernel.exec('sh', '-c', line)
                exit 1
            end
        end

        threads = Integer(job.expand_params(job.threads.to_s, false, jobs))
        @running[pid] = [job.name, threads]
        @usage += threads
    end

    def job_completed(pid)
        return nil unless @running[pid]

        @usage -= @running[pid][1]
        name = @running[pid][0]
        @running[pid] = nil

        return name
    end

    def host
        @host
    end

    def cores
        @cores
    end

    def usage
        @usage
    end

    def usage=(u)
        @usage = u
    end
end


class StatusScreen
    def initialize
        @done = []
        @failed = []
        @in_progress = []
        @queue = []
        @aliases = {}

        self.refresh
    end

    def write(s)
        $stdout.write(s)
        $stdout.flush
    end

    def path_store(hash, fpath, path, obj)
        if path.empty?
            return
        end

        key = path.shift
        hash[key] = [{}] unless hash[key]
        if path.empty?
            hash[key] << obj
        else
            path_store(hash[key][0], fpath + '/' + key, path, obj)
        end
    end

    def dir_split(list, aliased=false)
        if list.empty? || (list.size == 1 && list[0] == 'root')
            return list
        end

        prefixes = { '/' => true }
        copy = list.map do |le|
            le = aliased ? le : @aliases[le]
            if le != 'root'
                parts = File.dirname(le).split('/')
                1.upto(parts.size - 1).map do |pl|
                    prefixes[parts[0..pl] * '/'] = true
                end
            end
            le
        end

        (copy + prefixes.keys).sort.map { |e|
            '  ' * e[0..-2].count('/') + e
        }
    end

    def refresh
        size = TermInfo.screen_size
        w = size[1]
        h = size[0]

        self.write("\e[2J\e[;H")

        self.write("%-*s%-*s%-*s%-*s\n" %
                   [w / 4 - 2, 'Done', w / 4 + 2, '| Failed',
                    w / 4, '| In progress', w / 4, '| Queued'])
        self.write('-' * (w / 4 - 2) + '+' + '-' * (w / 4 + 1) +
                   '+' + '-' * (w / 4 - 1) + '+' + '-' * (w / 4 - 1) + "\n")

        din = dir_split(@done)
        fin = dir_split(@failed, true)
        pin = dir_split(@in_progress)
        qin = dir_split(@queue)

        i = 0

        while (din[i] || fin[i] || pin[i] || qin[i]) && i < h - 3
            d = din[i] ? din[i] : ''
            f = fin[i] ? fin[i] : ''
            p = pin[i] ? pin[i] : ''
            q = qin[i] ? qin[i] : ''

            self.write("%s| %s| %s| %s\n" %
                       [pad(d, w / 4 - 2),
                        pad(f, w / 4),
                        pad(p, w / 4 - 2),
                        pad(q, w / 4 - 2)])

            i += 1
        end

        while i < h - 3
            self.write(' ' * (w / 4 - 2) + '|' + ' ' * (w / 4 + 1) +
                       '|' + ' ' * (w / 4 - 1) + '|' + ' ' * (w / 4 - 1) + "\n")
            i += 1
        end
    end

    def summary
        self.write("\e[2J\e[;H")

        puts("=== Done ===")
        puts

        @done.map { |d| @aliases[d] }.sort.each do |d|
            puts(d)
        end

        if !@failed.empty?
            puts
            puts("=== Failed ===")
            puts

            @failed.sort.each do |f|
                puts(f)
            end
        end
    end

    def enqueue(op, desc)
        @aliases[op] = desc
        @queue += [op]
        self.refresh
    end

    def begin(op)
        @queue -= [op]
        @in_progress += [op]
        self.refresh
    end

    def done(op)
        @in_progress -= [op]
        @done += [op]
        self.refresh
    end

    def failed(op)
        @in_progress -= [op]
        op = @aliases[op]
        @failed += [op] unless @failed.include?(op)
        self.refresh
    end

    def notrun(op)
        @queue -= [op]
        self.refresh
    end

    def update_desc(op, desc)
        @aliases[op] = desc
        self.refresh
    end
end


$params = {}

$rcwd = File.realpath(Dir.pwd)

system('mkdir -p ' + LOG_PATH.shellescape)
system('mkdir -p ' + ERR_PATH.shellescape)

root = Job.new('root')
root.path = $rcwd
root.short_name = 'root'

all_jobs = { 'root' => root }
unloaded_deps = [ 'root' ]

ARGV.each do |arg|
    if arg.start_with?('--')
        p = arg[2..-1].split('=')
        cmd = p[0]
        arg = p[1..-1] * '='

        case cmd
        when 'param-file'
            if arg.empty?
                $stderr.puts('--param-file requires an argument')
                exit 1
            end
            begin
                params = JSON.parse(IO.read(arg))
            rescue
                $stderr.puts("Failed to read and parse parameter file #{arg}")
                raise
            end
            if !params.kind_of?(Hash) ||
               params.values.find { |v| !v.kind_of?(String) }
                $stderr.puts("Parameter file #{arg} does not contain a JSON " +
                             "with purely string values")
                exit 1
            end
            $params = $params.merge(params)
        when 'help'
            $stderr.puts('Usage: lants.rb [options...] ' +
                         '[root dependencies...] [parameters...]')
            $stderr.puts
            $stderr.puts('Options:')
            $stderr.puts('  --param-file=<file>: Specifies a JSON file from ' +
                         'which to read parameters')
            $stderr.puts
            $stderr.puts('root dependencies: Dependencies for the implicit ' +
                         'root job')
            $stderr.puts('  (i.e., list of jobs to execute)')
            $stderr.puts
            $stderr.puts('Parameters: Assignments of the form param=value')
            exit
        else
            $stderr.puts("Unknown option --#{cmd}")
            exit 1
        end
    elsif arg.include?('=')
        p = arg.split('=')
        $params[p[0].strip] = (p[1..-1] * '=').strip
    else
        root.soft_dependencies << arg
    end
end

root.expand_dependencies


stat = StatusScreen.new
stat.enqueue(root.name, root.short_name)


while !unloaded_deps.empty?
    job = all_jobs[unloaded_deps.shift]

    (job.dependencies + job.soft_dependencies).each do |dep|
        next if all_jobs[dep]

        begin
            new_job_desc = JSON.parse(IO.read(dep))
        rescue
            $stderr.puts('Job ' + dep + ': Failed to read job description')
            raise
        end

        if new_job_desc['arguments']
            unsatisfied_params = new_job_desc['arguments'].reject { |a| $params[a] }
            if !unsatisfied_params.empty?
                $stderr.puts('Job ' + dep + ': Missing arguments: ' + unsatisfied_params * ', ')
                exit 1
            end
        end

        new_job = Job.new(dep)
        new_job.path = File.dirname(dep)
        new_job.short_name = dep.sub($rcwd, '').sub(/\.json$/, '')
        begin
            new_job.from(new_job_desc)
        rescue
            $stderr.puts('Job ' + dep + ': Failed to load job')
            raise
        end

        all_jobs[dep] = new_job
        unloaded_deps << dep

        stat.enqueue(new_job.name, new_job.short_name)
    end
end


machines = {}

all_jobs.each do |_, job|
    if !machines[job.machine]
        machines[job.machine] = Machine.new(job.machine)
    end
end


jobs_completed = []
jobs_failed = []
jobs_notrun = []
jobs_running = []
job_pool = all_jobs.keys

fail_retries = 0


job_count = job_pool.size

while !job_pool.empty? || !jobs_running.empty?
    job = nil

    machines.each do |mn, machine|
        next if machine.usage > machine.cores

        if machine.usage < machine.cores
            job = job_pool.find { |j|
                j = all_jobs[j]

                j.machine == mn &&
                    (j.dependencies & jobs_completed) == j.dependencies &&
                    (j.soft_dependencies & (job_pool + jobs_running)).empty?
            }
        else
            job = job_pool.find { |j|
                j = all_jobs[j]

                j.machine == mn &&
                    j.threads == 0 &&
                    (j.dependencies & jobs_completed) == j.dependencies &&
                    (j.soft_dependencies & (job_pool + jobs_running)).empty?
            }
        end
        break if job
    end
    job = all_jobs[job]

    if job
        machine = machines[job.machine]

        job_ready_count =
            job_pool.select { |j|
                j = all_jobs[j]

                j.machine == machine.host &&
                    (j.dependencies & jobs_completed) == j.dependencies &&
                    (j.soft_dependencies & (job_pool + jobs_running)).empty?
        }.size

        job_jobs = 1
        if job.variable_jobs
            job_jobs = machine.cores - machine.usage
            job_jobs -= (job_ready_count - 1)
            job_jobs = 1 if job_jobs < 1
        end

        stat.begin(job.name)
        machine.execute_job(job, job_jobs)
        job_pool -= [job.name]
        jobs_running += [job.name]
    else
        if jobs_running.empty?
            $stderr.puts('Cannot fulfill remaining dependencies:')
            job_pool.each do |job|
                ud = job.dependencies - (job.dependencies & jobs_completed)
                ud += job.soft_dependencies & (job_pool + jobs_running)
                udl = ud.map { |d| all_jobs[ud].short_name } * ', '
                $stderr.puts("#{job.short_name} -> #{udl}")
            end
            exit 1
        end

        pid, status = Process.wait2
        job = machines.map { |_, machine| machine.job_completed(pid) }.select { |j| j }
        if job.empty?
            $stderr.puts('Unknown child ' + pid + ' exited')
            exit 1
        end
        if job.size > 1
            $stderr.puts('Huh, job ' + pid + ' was running on multiple machines?')
            job.each do
                $stderr.puts(job.inspect)
            end
            exit 1
        end

        job = all_jobs[job[0]]

        if !status.success?
            stat.update_desc(job.name,
                             "#{job.short_name} [#{job.failcount}]")
            stat.failed(job.name)

            machine = machines[job.machine]

            system("cp #{job_log_path(machine.host, job).shellescape} " +
                      "#{job_err_path(machine.host, job).shellescape}.#{job.failcount}")

            if job.failcount > 0
                job.failcount -= 1
                stat.enqueue(job.name, "#{job.short_name} [#{job.failcount}]")
                jobs_running -= [job.name]
                job_pool += [job.name]

                fail_retries += 1
            else
                jobs_running -= [job.name]
                jobs_failed += [job.name]

                skip = job_pool.select { |j|
                    all_jobs[j].dependencies.include?(job.name)
                }
                while !skip.empty?
                    skip.each do |j|
                        stat.notrun(j)
                    end

                    jobs_notrun += skip
                    job_pool -= skip

                    skip = job_pool.select { |j|
                        !(all_jobs[j].dependencies & skip).empty?
                    }
                end
            end
            next
        end

        stat.done(job.name)
        jobs_running -= [job.name]
        jobs_completed += [job.name]
    end
end


stat.summary

puts
puts
if jobs_failed.empty? && jobs_notrun.empty?
    puts('All jobs completed successfully.')
else
    puts('The following jobs failed terminally:')
    jobs_failed.each do |j|
        puts(' · ' + all_jobs[j].short_name)
    end
    puts

    puts('The following jobs were not run because of failed dependencies:')
    jobs_notrun.each do |j|
        puts(' · ' + all_jobs[j].short_name)
    end
    puts
end
if fail_retries > 0
    puts("(#{fail_retries} retr#{fail_retries == 1 ? 'y' : 'ies'} because of failure)")
end
