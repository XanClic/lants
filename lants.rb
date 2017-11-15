#!/usr/bin/ruby

require 'json'
require 'shellwords'
require 'terminfo'


LOG_PATH = '/tmp/lants-output'


def fname_friendly(str)
    str.gsub('/', '__').gsub(/[^\w-]/, '_')
end

def job_fname(host, job)
    fname_friendly(host + '-' + job.short_name.gsub(/^\//, ''))
end

def job_log_path(host, job)
    LOG_PATH + '/' + job_fname(host, job)
end


class Job
    def initialize(name)
        @name = name
        @path = nil
        @short_name = nil
        @dependencies = []
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

    def from(desc)
        @dependencies = desc['depends'] if desc['depends']
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
        elsif @threads != '$__jobs'
            raise ':threads must be a non-negative integer or "$__jobs"'
        end

        if @threads == '$__jobs' && !@variable_jobs
            if @execute.empty?
                @threads = 0
            else
                @threads = 1
            end
        end

        self.expand_dependencies
    end

    def expand_dependencies
        @dependencies.map! do |dep|
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

            dep
        end
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
            `ssh #{@host} #{cmd.shellescape}`
        end
    end

    def execute_job(job, jobs=1)
        args = Hash[job.arguments.map { |a| [a, $params[a].gsub('$', '$$')] }]
        args['__jobs'] = jobs.to_s
        args['__fname'] = job_fname(@host, job).shellescape

        execution = ['cd ' + job.workdir.shellescape] + job.execute.map { |l|
            args.each do |a, v|
                l.gsub!(/([^$])\$#{a}/, '\1' + v.gsub('\\', '\\\\'))
                l.gsub!(/^\$#{a}/, v.gsub('\\', '\\\\'))
            end
            l.gsub!('$$', '$')

            l
        }

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
                line += ' &> ' + job_log_path(@host, job).shellescape
                Kernel.exec('sh', '-c', line)
                exit 1
            end
        end

        threads = job.threads == '$__jobs' ? jobs : job.threads
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
        if list.empty?
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

        #self.write("\e[2J\e[;H")

        self.write("%-*s%-*s%-*s%-*s\n" %
                   [w / 4, 'Done', w / 4, '| Failed',
                    w / 4, '| In progress', w / 4, '| Queued'])
        self.write('-' * (w / 4) + '+' + '-' * (w / 4 - 1) +
                   '+' + '-' * (w / 4 - 1) + '+' + '-' * (w / 4 - 1) + "\n")

        din = dir_split(@done)
        fin = dir_split(@failed, true)
        pin = dir_split(@in_progress)
        qin = dir_split(@queue)

        i = 0
        dbi = din.length - h + 3
        fbi = fin.length - h + 3
        pbi = pin.length - h + 3
        qbi = qin.length - h + 3

        dbi = 0 if dbi < 0
        fbi = 0 if fbi < 0
        pbi = 0 if pbi < 0
        qbi = 0 if qbi < 0

        while din[dbi + i] || fin[fbi + i] || pin[pbi + i] || qin[qbi + i]
            d = din[dbi + i]
            f = fin[fbi + i]
            p = pin[pbi + i]
            q = qin[qbi + i]

            d = d ? d : ''
            f = f ? f : ''
            p = p ? p : ''
            q = q ? q : ''

            self.write("%-*.*s%-*.*s%-*.*s%-*.*s\n" %
                       [w / 4, w / 4, d,
                        w / 4, w / 4, '| ' + f,
                        w / 4, w / 4, '| ' + p,
                        w / 4, w / 4, '| ' + q])

            i += 1
        end

        while i < h - 3
            self.write(' ' * (w / 4) + '|' + ' ' * (w / 4 - 1) +
                       '|' + ' ' * (w / 4 - 1) + '|' + ' ' * (w / 4 - 1) + "\n")
            i += 1
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

    def update_desc(op, desc)
        @aliases[op] = desc
        self.refresh
    end
end


$params = {}

$rcwd = File.realpath(Dir.pwd)

system('mkdir -p ' + LOG_PATH.shellescape)

stat = StatusScreen.new

root = Job.new('root')
root.path = $rcwd
root.short_name = 'root'

all_jobs = { 'root' => root }
unloaded_deps = [ 'root' ]

stat.enqueue(root.name, root.short_name)

ARGV.each do |arg|
    if arg.include?('=')
        p = arg.split('=')
        $params[p[0].strip] = (p[1..-1] * '=').strip
    else
        root.dependencies << arg
    end
end

root.expand_dependencies


while !unloaded_deps.empty?
    job = all_jobs[unloaded_deps.shift]

    job.dependencies.each do |dep|
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
jobs_running = []
job_pool = all_jobs.keys


job_count = job_pool.size

while jobs_completed.size < job_count
    job = nil

    machines.each do |mn, machine|
        next if machine.usage > machine.cores

        if machine.usage < machine.cores
            job = job_pool.find { |j| j = all_jobs[j];
                                      j.machine == mn &&
                                          (j.dependencies & jobs_completed) ==
                                              j.dependencies }
        else
            job = job_pool.find { |j| j = all_jobs[j];
                                      j.machine == mn && j.threads == 0 &&
                                          (j.dependencies & jobs_completed) ==
                                              j.dependencies }
        end
        break if job
    end
    job = all_jobs[job]

    if job
        machine = machines[job.machine]

        job_ready_count =
            job_pool.select { |j| j = all_jobs[j];
                              j.machine == machine.host &&
                                      (j.dependencies & jobs_completed) ==
                                          j.dependencies }.size

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

            if job.failcount > 0
                log_path = job_log_path(machine.host, job)
                system("cp #{log_path.shellescape} " +
                       "#{log_path.shellescape}.#{job.failcount}")
                job.failcount -= 1
                stat.enqueue(job.name, "#{job.short_name} [#{job.failcount}]")
                jobs_running -= [job.name]
                job_pool += [job.name]
            else
                $stderr.puts("\n\n#{job.name} failed; see logs under " +
                             job_log_path(machine.host, job))
                exit 1
            end
            next
        end

        stat.done(job.name)
        jobs_running -= [job.name]
        jobs_completed += [job.name]
    end
end
